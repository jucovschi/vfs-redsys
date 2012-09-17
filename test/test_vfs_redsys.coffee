root = "http://localhost:8080/rest/";
redsys = require('../vfs_redsys')
async = require('async');
vfs = new redsys();

genOutput = (text) ->
  output = "";
  text.replace(/\\importmodule\[.*\]\{.*\}/g, (match) ->
    output+=match+"\n";
    )
  return output

manageChange = (srcHandler, destHandler, _callback) ->
  async.waterfall([
    (callback) -> srcHandler.getText(callback),
    (text, callback) -> destHandler.setText(genOutput(text), _callback)
  ]);

  
transform = (srcHandler, destHandler, _callback) ->
  async.waterfall([
    (callback) -> srcHandler.getSnapshot(callback),
    (snapshot, callback) ->
      srcHandler.on("op", (op) ->
        
      )
      srcHandler.startListening(snapshot.v, callback)
      manageChange(srcHandler, destHandler, _callback);
  ]);

vfs.registerGlobalTranslator("tex", { res: "sms", mime: "application/x-sms", handleTransformation: transform});

require('http').createServer(require('stack')(
  require('vfs-http-adapter')("/rest/", vfs)
) ).listen(8080);

  
vfs.readfile("/test2.sms", {}, (err, result) ->
    console.log(err, result);
  )
