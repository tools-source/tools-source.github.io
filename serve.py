import http.server, os

os.chdir("/Users/majdinagi/Documents/musicapp")
handler = http.server.SimpleHTTPRequestHandler
httpd = http.server.HTTPServer(("0.0.0.0", 8080), handler)
print("MusicTube site server listening on 8080")
httpd.serve_forever()
