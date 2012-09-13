sharejs = require("share").server;
async = require("async");
localfs = require("vfs-local")
extend = require("deep-extend")
Path = require("path")
async = require("async")
Stream = require("stream");

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

  # loads file contents into a string 
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

  applyTransform = (src, dest, translator, callback) ->
    # transformation was already established
    destName = getDocName(dest); 
    if (docs[dest])
      callback(null, {"status":"here is the source "});
      return;
    async.waterfall([
      # make sure source document is in the model 
      (callback) -> if docs[src] then callback() else loadDoc(src, callback),
      # create destination document in the model
      (callback) -> model.create(destName, translator.type, {}, callback),
      # 
      (callback) -> 
        docs[dest] = true;
        
    ], (err, data) ->
      console.log(err, data);
      );

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
    registerGlobalTranslator : (ext, options, callback) ->
      options.src = ext;
      translators["."+ext]?=[];
      translators["."+ext].push(options);
      inv["."+options.res]?=options;
  }
