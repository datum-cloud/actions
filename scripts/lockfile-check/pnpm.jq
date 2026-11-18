def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "?");

def row($name; $source): "\($name | clean)\t\($source | clean)";

def anchor($importer):
  if $importer == "." then .
  else
    (capture("^(?<lead>[^:]*):(?<rest>.*)$")? // null) as $m
    | if $m == null or (($m.lead != "link" and $m.lead != "file") or ($m.rest | test("^[/~]"))) then .
      else $m.lead + ":" + $importer + "/" + $m.rest
      end
  end;

def depvalue($importer):
  tostring
  | if startswith("/") then ""
    else sub("\\(.*$"; "")
      | if test("^(@[^/]+/)?[^/@:]+@[^/:]+$") then "" else anchor($importer) end
    end;

def dependency_map($importer):
  to_entries[]
  | .key as $name | .value as $entry
  | if ($entry | type) == "object" then
      (if ($entry | has("version")) then row($name; $entry.version | depvalue($importer)) else empty end),
      (if ($entry | has("specifier")) and (($entry.specifier | tostring | startswith("catalog:")) | not)
       then row($name; $entry.specifier | depvalue($importer)) else empty end)
    elif ($entry | type) == "string" and ($entry | startswith("catalog:")) then empty
    else row($name; $entry | depvalue($importer))
    end;

def dependency_blocks($importer):
  (.dependencies, .devDependencies, .optionalDependencies)
  | select(type == "object")
  | dependency_map($importer);

def resolution($name; $r):
  if ($r | type) != "object" then row($name; "resolution:" + ($r | tostring))
  else
    (if ($r | has("tarball")) then row($name; $r.tarball // "") else empty end),
    (if ($r | has("repo")) then row($name; "git+" + ($r.repo | tostring)) else empty end),
    (if ($r | has("directory")) then row($name; "file:" + ($r.directory | tostring)) else empty end),
    (($r.type // null) as $type
     | if $type == "git" then (if ($r | has("repo")) then empty else row($name; "git:") end)
       elif $type == null or $type == "directory" then empty
       else row($name; "resolution-type:" + ($type | tostring))
       end),
    (if ($r | has("commit")) and ($r | has("repo") | not) and (($r.type // null) != "git") then row($name; "git:") else empty end),
    (if ($r | has("tarball") or has("repo") or has("directory") or has("type") or has("commit")) then empty else row($name; "") end)
  end;

def key_source($name):
  if ($name | test("^(@[^/@]+/)?[^/@]+@")) then
    ($name | capture("^(?<n>(@[^/@]+/)?[^/@]+)@(?<s>.*)$").s | sub("\\(.*$"; ""))
  else null
  end;

def package_entries:
  to_entries[]
  | .key as $name | .value as $entry
  | (key_source($name) as $s | if $s == null then empty else row($name; $s) end),
    (if ($entry | type) != "object" then row($name; "resolution:missing")
     else
       (if ($entry | has("resolution")) then resolution($name; $entry.resolution) else row($name; "resolution:missing") end),
       (if ($entry | has("version")) then row($name; $entry.version | depvalue(".")) else empty end),
       ($entry | dependency_blocks("."))
     end);

def snapshot_entries:
  to_entries[]
  | .key as $name | .value
  | select(type == "object")
  | dependency_blocks(".");

if type != "object" then error("not a mapping") else . end
| dependency_blocks("."),
  ((.importers // {}) | to_entries[] | .key as $importer | .value | select(type == "object") | dependency_blocks($importer)),
  ((.catalogs // {}) | to_entries[] | .value | select(type == "object") | dependency_map(".")),
  ((.packages // {}) | package_entries),
  ((.snapshots // {}) | snapshot_entries)
