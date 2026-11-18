def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "?");

def row($name; $source): "\($name | clean)\t\($source | clean)";

def deps:
  (.dependencies // {}) | to_entries[]
  | .key as $name | .value as $entry
  | (if ($entry.resolved // null) != null then row($name; $entry.resolved) else empty end),
    row($name; $entry.version // ""),
    ($entry | deps);

def packages:
  (.packages // {}) | to_entries[] | select(.key != "")
  | .key as $path | .value as $entry
  | if ($path | test("(^|/)node_modules/")) then
      if ($entry.link // false) == true
      then row($path; "link:" + ($entry.resolved // ""))
      else row($path; $entry.resolved // "")
      end
    else row($path; "file:" + $path)
    end;

packages, deps
