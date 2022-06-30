
import sys.io.File;

using StringTools;

function main() {

    // Need to replace this output from haxe compiler for now,
    // because vscode doesn't like String.prototype.__class__ = ...
    var js = File.getContent('vscode-ceramic.js');
    var newJs = js.replace(
        "String.prototype.__class__ = $hxClasses[\"String\"] = String;",
        "$hxClasses[\"String\"] = String; Object.defineProperty(String.prototype, \"__class__\", { value: String, enumerable: false });"
    );
    if (newJs != js) {
        File.saveContent('vscode-ceramic.js', newJs);
    }

}