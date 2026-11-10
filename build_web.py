"""Wraps the shared app page (leksika.html) into a full HTML document for the iOS bundle."""
import sys, pathlib
src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "../leksika.html").read_text(encoding="utf-8")
head = ('<!doctype html><html lang="ru"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover">'
        '<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}'
        'body{margin:0;font:14px system-ui,-apple-system,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>'
        '</head><body>')
out = pathlib.Path("Resources/web/index.html")
out.write_text(head + src + "</body></html>", encoding="utf-8")
print("wrote", out, out.stat().st_size, "bytes")
