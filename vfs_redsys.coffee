sharejs = require("share").server;
async = require("async");
localfs = require("vfs-local")
extend = require("deep-extend")
Path = require("path")
async = require("async")
Stream = require("stream");
{EventEmitter} = require 'events'

createFS = (options) ->
  return switch options.type
    when "local" then localfs(options);
    else throw new Error "Cannot init VFS type '#{options.type}'";

module.exports = (_opt) ->
  options = 
    db : 
      type: "none",
    fs :
      type: "local",
      root: Path.resolve("./fs")
    defaultType: "text"

  docs = {};
  extend(options, _opt);
  model = sharejs.createModel(options)
  vfs = createFS(options.fs)
  
  translators = {};
  inv = {};

  # loads VFS file contents into a string 
  loadVFSFile = (path, callback) ->
    vfs.readfile(path, {encoding:'utf8'}, (err, meta) ->
      if err
        callback(err);
        return;
      data = '';
      meta.stream.on("data", (item) ->
        data += item;
        )
      meta.stream.on("end", () ->
        callback(null, data);
        )
    );

  # wraps around snapshot object to expose it's functions better
  wrapSnapshot = (doc, callback) ->
    _self = @;
    _doc = doc;
    composedOp = null;
    _doc.submitOp = (op) ->
      if (composedOp == null)
        composedOp = op;
      else
        composedOp = _doc.type.compose(composedOp, op);
    return callback(null, {
      v : _doc.v,
      getOriginal : () -> _doc,
      getText : () -> _doc.type.api.getText.apply(_doc),
      getLength : () -> _doc.type.api.getLength.apply(_doc)
      del : (pos, len) -> _doc.type.api.del.apply(_doc, [pos, len]),
      insert : (pos, text) -> _doc.type.api.insert.apply(_doc, [pos, text]),
      getDelta : () -> composedOp
    });

  # creates a (possibly readonly) handler to a file 
  createDocumentHandler = (docName, readonly = true) ->
    handler = 
      name : docName,
      readonly : readonly,
      getSnapshot : (callback) -> 
        async.waterfall([
          (callback) -> model.getSnapshot(docName, callback),
          (doc, callback) -> wrapSnapshot(doc, callback)
        ], callback);

      getText : (_callback) ->
        _self = @;
        async.waterfall([
          (callback) -> _self.getSnapshot(callback),
          (doc, callback) -> callback(null, doc.getText())
        ], _callback);
        
      startListening : (version, callback) ->
        if (@listening)
          callback();
          return;
        @listening = true;
        @listener = (op) ->
          @emit("op", op);
        model.listen(docName, version, @listener, callback);
        
      stopListening : () ->
        @listening = false;
        model.removeListener(@listener);
    extend(handler, new EventEmitter());
    return handler unless !readonly
    extend(handler, 
      setText : (text, _callback) ->
        _self = @;
        async.waterfall([
          (callback) -> _self.getSnapshot(callback),
          (snapshot, callback) ->
            len = snapshot.getLength();
            snapshot.del(0, len);
            snapshot.insert(0, text);
            model.applyOp(docName, { v : snapshot.v, op : snapshot.getDelta() }, callback)
         (ver, callback) ->
           callback();
        ], _callback);
    )
    return handler;
  
  getDocName = (path) ->
    return path.replace("/","_");

  # loads file from VFS into the model
  loadDoc = (path, _callback) ->
    docName = getDocName(path);
    async.waterfall([
      (callback) -> model.create(docName, options.defaultType, {}, callback) 
      (callback) -> loadVFSFile(path, callback)
      (data, callback) ->
        model.getSnapshot(docName, (err, doc) ->
          if err
            callback(err)
          doc.type.api.insert.apply({
            "snapshot" : doc.snapshot,
            "submitOp" : (op) ->
              callback(null, op);
            }, [0, data]);
          )
      (op, callback) -> model.applyOp(docName, { v : 0, op : op } , callback);
      (ver, callback) ->
        docs[path] = true;
        callback();
      ], _callback);
      
  prepareSnapshot = (doc, callback) ->
    text = doc.type.api.getText.apply(doc);
    meta = {};
    meta.size = text.length;
    meta.mime = "text/plain";
    meta.stream = new Stream();
    meta.stream.readable = true;
    callback(null, meta);
    meta.stream.emit("data", text);
    meta.stream.emit("end");
    meta.stream.emit("close");

  applyTransform = (src, dest, translator, _callback) ->
    # transformation was already established
    srcName = getDocName(src); 
    destName = getDocName(dest); 
    if (docs[dest])
      async.waterfall([
        (callback) -> model.getSnapshot(destName, callback),
        (doc, callback) -> prepareSnapshot(doc, callback);
      ], _callback);
      return;
    async.waterfall([
      # make sure source document is in the model 
      (callback) -> if docs[src] then callback() else loadDoc(src, callback),
      # create destination document in the model
      (callback) ->
        model.create(destName, translator.type, {}, callback)
      # init the transformation 
      (callback) -> 
        docs[dest] = true;
        translator.handleTransformation(createDocumentHandler(srcName), createDocumentHandler(destName, false), callback)
      (callback) -> model.getSnapshot(destName, callback)
      (doc, callback) -> prepareSnapshot(doc, callback);
    ], _callback);

  return {
    readfile : (path, options, callback) ->
      _self = @;
      vfs.readfile(path, options, (err, result) ->
        if err
          # might be that the file is virtual
          ext = Path.extname(path);
          if inv[ext]
            newName = path.substr(0, path.length-ext.length)+"."+inv[ext].src
            _self.stat(newName, options, (err1, result1) ->
              if err1
                # giving up
                callback(err, result);
                return;
              applyTransform(newName, path, inv[ext], callback);
              )
          else
            callback(err, result);
        else
          callback(err, result);
        );
      
    readdir : (path, options, callback) ->
      async.waterfall([
        (callback) -> vfs.readdir(path, options, callback),
        (meta, callback) ->
          expStream = new Stream();
          origStream = meta.stream;
          expStream.readable = true;
          origStream.on("data", (item) ->
            expStream.emit("data", item);
            ext = Path.extname(item.name);
            for t in translators[ext]
              expStream.emit("data",
                name : item.name.substr(0, item.name.length-ext.length)+"."+t.res,
                mtime : item.mtime,
              );
            )
          meta.stream = expStream;
          callback(null, meta);
      ], 
      (err, result...) ->
        callback(err, result...);
      );
    stat : (path, options, callback) ->
      vfs.stat(path, options, callback);
    mkfile : (path, options, callback) ->
      vfs.mkfile(path, options, callback);
    mkdir : (path, options, callback) ->
      vfs.mkdir(path, options, callback);
    rmfile : (path, options, callback) ->
      vfs.rmfile(path, options, callback);
    rmdir : (path, options, callback) ->
      vfs.rmdir(path, options, callback);
    rename : (path, options, callback) ->
      vfs.rename(path, options, callback);    
    copy : (path, options, callback) ->
      vfs.copy(path, options, callback);
    symlink : (path, options, callback) ->
      vfs.symlink(path, options, callback);
    registerGlobalTranslator : (ext, _options, callback) ->
      _options.src = ext;
      opt = 
        type: "text",
        mime: 'text/plain',
      extend(opt, _options);
      translators["."+ext]?=[];
      translators["."+ext].push(opt);
      inv["."+opt.res]?=opt;
  }
