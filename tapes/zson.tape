Output assets/zson-vhs.gif

Require zig

Set Shell "bash"
Set FontFamily "Menlo"
Set FontSize 22
Set Width 1400
Set Height 620
Set Padding 28
Set BorderRadius 12
Set WindowBar Colorful
Set Theme "Dracula"
Set TypingSpeed 18ms
Set Framerate 24

Type "zig build -Doptimize=ReleaseFast" Sleep 300ms Enter
Sleep 900ms

Type "# count matches" Sleep 150ms Enter
Type "./zig-out/bin/zson '"
Type '{"age":{"$gt":30}}'
Type "' examples/sample.ndjson --count" Sleep 300ms Enter
Sleep 1200ms

Type "# project fields as CSV" Sleep 150ms Enter
Type "./zig-out/bin/zson '"
Type '{"city":"NYC"}'
Type "' examples/sample.ndjson --select id,name,age --output csv" Sleep 300ms Enter
Sleep 1600ms

Ctrl+L
Sleep 300ms

Type "# limit results and pretty-print JSON" Sleep 150ms Enter
Type "./zig-out/bin/zson '"
Type '{"active":true}'
Type "' examples/sample.ndjson --limit 2 --output json --pretty" Sleep 300ms Enter
Sleep 1800ms

Type "# regex with case-insensitive options" Sleep 150ms Enter
Type "./zig-out/bin/zson '"
Type '{"name":{"$regex":"^a","$options":"i"}}'
Type "' examples/sample.ndjson --select id,name,city" Sleep 300ms Enter
Sleep 1600ms

Ctrl+L
Sleep 300ms

Type "# JSON array from stdin" Sleep 150ms Enter
Type "printf '["
Type '{"n":"Ada","s":92},{"n":"Lin","s":71}'
Type "]' | ./zig-out/bin/zson '"
Type '{"s":{"$gte":90}}'
Type "' - --output json --pretty" Sleep 300ms Enter
Sleep 2500ms
