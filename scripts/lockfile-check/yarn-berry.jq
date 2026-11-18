def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "?");

def row($name; $source): "\($name | clean)\t\($source | clean)";

def locator_row:
  clean
  | (capture("^(?<name>.[^@]*)@(?<source>.*)$") // {name: ., source: .}) as $m
  | row($m.name; $m.source);

def resolution_of:
  if type == "object" and (.resolution | type) == "string" then .resolution
  else error("entry without exactly one resolution")
  end;

if type != "object" then error("not a mapping") else . end
| [to_entries[] | select(.key != "__metadata") | .value | resolution_of | locator_row] as $records
| ([to_entries[] | select(.key != "__metadata")] | length) as $entries
| if ($records | length) != $entries then error("entry count differs from record count") else $records[] end
