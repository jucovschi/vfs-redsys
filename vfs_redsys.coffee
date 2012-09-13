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
  docs = {};
  extend(options, _opt);
  model = sharejs.createModel(options)
  vfs = createFS(options.fs)
  translators = {};
  inv = {};

  # loads file contents into a string 
  loadVFSFile = (path, _callback) ->
    async.waterfall([
      (callback) -> vfs.readfile(path, {}, callback),
      (meta, callback) ->
        data = '';
        meta.stream.on("data", (item) ->
          data += item.toString();
          )
        meta.stream.on("end", () ->
          callback(null, data);
          )
        return;
    ], _callback);

  getDocName = (path) ->
    return path.replace("/","_");

  # loads file from VFS into the model
  loadDoc = (path, _callback) ->
    docName = getDocName(path);
    async.waterfall([
      (callback) -> model.create(docName, "text", {}, callback) 
      (callback) -> loadVFSFile(path, callback)
      (data, callback) ->
        model.applyOp(docName,
          v : 0,
          op : [
            i : data
            p : 0
          ]
        , callback);
      (ver, callback) -> callback()
      ], _callback);

  applyTransform = (src, dest, translator, callback) ->
    # we have the original source already in memory
    if (docs[dest])
      callback(null, {"status":"here is the source "});
      return;
    if typeof(docs[src])=="undefined"
      async.waterfall([
        (callback) -> loadDoc(src, callback),
        (callback) -> model.getSnapshot(getDocName(src), callback),
        (data, callback) -> console.log(data);
      ]);
    callback(null, {"status":"ehmmm"});
  
  return {
    readfile : (path, options, callback) ->
      _self = @;
      vfs.readfile(path, options, (err, result) ->
        if err
          # might be that the file is virtual
          ext = Path.extname(path);
          if inv[ext]
            newName = path.substr(0, path.length-ext.length)+"."+inv[ext]
            _self.stat(newName, options, (err1, result1) ->
              if err1
                # giving up
                callback(err, result);
                return;
              applyTransform(newName, path, translators["."+inv[ext]], callback);
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
      translators["."+ext]?=[];
      translators["."+ext].push(options);
      inv["."+options.res]?=ext;
  }
