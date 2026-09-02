#!/usr/bin/env bash
# ux-graph-scan.sh — deterministic, dependency-free half of /kit-ux-audit (flows lane).
#
# Two modes, no model call, no API key:
#   --apps <root>   enumerate app-like packages (react/next/vue + a dev script)  -> JSON array
#   --scan <dir>    build an APPROXIMATE flows graph of one app                   -> graphify-out/.ux_graph.json
#
# The scan is regex over TS/TSX/JSX/Vue, not an AST. It is the fallback for when no
# graphify-out/graph.json exists; the skill marks the report "graph source: deterministic scan".
# macOS-safe (no grep -P). Requires: jq, perl. Sources scripts/lib/react-detect.sh for --apps.
set -eu   # no pipefail: many probes end in a grep that legitimately finds nothing

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
USAGE="usage: ux-graph-scan.sh --apps <root> | --scan <dir> [--exclude <regex>]"

MODE=""; ARG=""; EXCLUDE='__never__'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apps)  MODE="apps";  ARG="${2:-}"; shift 2 ;;
    --scan)  MODE="scan";  ARG="${2:-}"; shift 2 ;;
    --exclude)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "ux-graph-scan: --exclude needs a value" >&2; exit 2; }
      EXCLUDE="$2"; shift 2 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "ux-graph-scan: unknown arg: $1" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done
[[ -n "$MODE" && -n "$ARG" ]] || { echo "$USAGE" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "ux-graph-scan: jq required" >&2; exit 3; }
command -v perl >/dev/null 2>&1 || { echo "ux-graph-scan: perl required" >&2; exit 3; }

# ----------------------------------------------------------------------------- apps
if [[ "$MODE" == "apps" ]]; then
  [[ -d "$ARG" ]] || { echo "ux-graph-scan: no such dir: $ARG" >&2; exit 2; }
  # shellcheck source=/dev/null
  [[ -f "$HERE/lib/react-detect.sh" ]] && . "$HERE/lib/react-detect.sh"
  printf '['
  first=1
  while IFS= read -r pkg; do
    dir="$(dirname "$pkg")"
    case "$dir" in *node_modules*|*/.next/*|*/dist/*) continue ;; esac
    has_dev="$(jq -r '(.scripts.dev // .scripts.start // "") | if . == "" then "0" else "1" end' "$pkg" 2>/dev/null || echo 0)"
    deps="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]?' "$pkg" 2>/dev/null || true)"
    fw=""
    printf '%s\n' "$deps" | grep -qx next        && fw="next"
    [[ -z "$fw" ]] && printf '%s\n' "$deps" | grep -qx '@react-router/dev' && fw="react-router"
    [[ -z "$fw" ]] && printf '%s\n' "$deps" | grep -qx nuxt  && fw="nuxt"
    [[ -z "$fw" ]] && printf '%s\n' "$deps" | grep -qx astro && fw="astro"
    [[ -z "$fw" ]] && printf '%s\n' "$deps" | grep -qx vue   && fw="vue"
    [[ -z "$fw" ]] && printf '%s\n' "$deps" | grep -qx react && fw="react"
    [[ -n "$fw" && "$has_dev" == "1" ]] || continue
    router="unknown"
    if declare -f react_detect >/dev/null 2>&1; then
      react_detect "$dir" || true
      [[ "$fw" == "next" && -d "$dir/app" ]] && router="app-router"
      [[ "$fw" == "next" && -d "$dir/pages" ]] && router="pages-router"
      [[ "$REACT_ROUTER_LIB" == "true" ]] && router="react-router-lib"
    fi
    [[ "$fw" == "astro" && -d "$dir/src/pages" ]] && router="file-routes"
    [[ ( "$fw" == "vue" || "$fw" == "nuxt" ) && -d "$dir/pages" ]] && router="file-routes"
    name="$(jq -r '.name // ""' "$pkg" 2>/dev/null)"; [[ -n "$name" ]] || name="$(basename "$dir")"
    [[ $first == 1 ]] || printf ','
    first=0
    jq -n --arg n "$name" --arg d "$dir" --arg f "$fw" --arg r "$router" \
      '{name:$n, dir:$d, framework:$f, router:$r}'
  done < <(find "$ARG" -name node_modules -prune -o -name package.json -type f -print 2>/dev/null | sort)
  printf ']\n'
  exit 0
fi

# ----------------------------------------------------------------------------- scan
[[ -d "$ARG" ]] || { echo "ux-graph-scan: no such dir: $ARG" >&2; exit 2; }
TARGET="$ARG"
OUTDIR="$TARGET/graphify-out"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/.ux_graph.json"

FILES="$(find "$TARGET" \( -name node_modules -o -name .next -o -name dist -o -name build \) -prune -o \
  -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.ts' -o -name '*.vue' \) -print 2>/dev/null \
  | grep -Ev "$EXCLUDE" | sort || true)"
NFILES="$(printf '%s\n' "$FILES" | grep -c . || true)"

# One perl pass over every file emits TSV rows the jq step below folds into nodes/edges.
# row kinds:  N<TAB>id<TAB>kind<TAB>label<TAB>file<TAB>metaJson
#             E<TAB>from<TAB>to<TAB>type<TAB>viaJson
# -0777 -n => one iteration per @ARGV file, $_ = whole file, $ARGV = that file.
perl -0777 -ne '
  my $rel = $ARGV;
  $rel =~ s{^\./}{};
  # ---- node kind from path -------------------------------------------------
  my $kind = "component";
  my $isRoute = 0;
  if    ($rel =~ m{(?:^|/)(?:src/)?app/(?:.*/)?page\.(?:tsx|jsx|ts)$})       { $kind="screen"; $isRoute=1 }
  elsif ($rel =~ m{(?:^|/)(?:src/)?pages/(?!_)[^.].*\.(?:tsx|jsx)$})         { $kind="screen"; $isRoute=1 }
  elsif ($rel =~ m{(?:^|/)(?:src/)?routes/.*\.(?:tsx|jsx)$})                 { $kind="screen"; $isRoute=1 }
  elsif ($rel =~ m{\.route\.(?:tsx|jsx|ts)$})                               { $kind="screen"; $isRoute=1 }
  elsif ($rel =~ m{(?:^|/)(?:src/)?app/(?:.*/)?layout\.(?:tsx|jsx|ts)$})     { $kind="container" }
  elsif ($rel =~ m{[Ll]ayout\.(?:tsx|jsx)$})                                { $kind="container" }
  my $id = "$kind:$rel";
  # ---- route path -------------------------------------------------------
  my $route = "";
  if ($isRoute) {
    ($route = $rel) =~ s{^.*?(?:^|/)(?:src/app|src/pages|src/routes|app|pages|routes)/}{};
    $route =~ s{/?(?:page|index|route)\.(?:tsx|jsx|ts)$}{};
    $route =~ s{\.(?:tsx|jsx)$}{};
    $route =~ s{\((\w+)\)/?}{}g;                # route groups
    $route =~ s{\[\.\.\.(\w+)\]}{*}g;
    $route =~ s{\[(\w+)\]}{:$1}g;
    $route = "/$route"; $route =~ s{//+}{/}g; $route =~ s{/$}{} ;
    $route = "/" if $route eq "";
  }
  my $entry = ($route =~ m{^/(|dashboard|home|inicio|overview|app)$}) ? "true" : "false";
  my $meta = sprintf(q({"route":"%s","entry":%s}), $route, $entry);
  print "N\t$id\t$kind\t$route\t$rel\t$meta\n";

  # ---- imports / renders ---------------------------------------------------
  while (/import\s+(?:\*\s+as\s+\w+|\{[^}]*\}|\w+)\s+from\s+["'\''](\.[^"'\'']+|\@\/[^"'\'']+)["'\'']/g) {
    my $spec = $1;
    print "E\t$id\timport:$spec\timports\t{}\n";
  }
  # ---- navigation -------------------------------------------------------
  while (/(?:href|to)=\s*["'\''](\/[A-Za-z0-9_\-\/:*]*)["'\'']/g)  { print "E\t$id\troute:$1\tnavigates-to\t{}\n"; }
  while (/(?:router\.push|router\.replace|redirect|navigate)\(\s*["'\''](\/[A-Za-z0-9_\-\/:*]*)["'\'']/g) { print "E\t$id\troute:$1\tnavigates-to\t{}\n"; }
  my $navcnt = () = /<Link\b|useNavigate\(|router\.(push|replace)/g;
  print "N\t$id.navmeta\t_navmeta\t\t$rel\t{\"nav\":$navcnt}\n" if $navcnt;

  # ---- data reads / writes / mutations ----------------------------------
  # prisma.<model>.<op>
  while (/\bprisma\.(\w+)\.(\w+)/g) {
    my ($m,$op)=($1,$2); my $ent = ucfirst($m); $ent =~ s/s$//;
    my $t = ($op=~/delete|deleteMany|remove/i) ? "mutates" : ($op=~/create|update|upsert|insert|createMany|updateMany/i ? "writes" : "reads");
    print "E\t$id\tdata-entity:$ent\t$t\t{\"op\":\"$op\"}\n";
  }
  # supabase .from("table")
  while (/\.from\(\s*["'\''](\w+)["'\'']\s*\)/g) { my $ent=ucfirst($1); $ent=~s/s$//; print "E\t$id\tdata-entity:$ent\treads\t{}\n"; }
  # react-query / swr hooks: useXxxQuery / useXxxMutation
  while (/\buse(\w+?)(Query|Mutation|SuspenseQuery)\b/g) {
    my ($ent,$hook)=($1,$2); next if $ent eq "";
    my $t = ($hook eq "Mutation") ? "writes" : "reads";
    $t = "mutates" if $ent =~ /Delete|Remove|Archive/;
    $ent =~ s/(Delete|Remove|Archive|Create|Update|List|Get)//g; next if $ent eq "";
    print "E\t$id\tdata-entity:$ent\t$t\t{\"via\":\"hook\"}\n";
  }
  # server actions / loaders
  print "E\t$id\tdata-entity:_loader\treads\t{}\n" if /useLoaderData\(|createServerFn\(|export\s+async\s+function\s+loader/;

  # ---- forms -----------------------------------------------------------
  if (/useForm\s*\(|<Formik\b|<form\b|zodResolver\(/) {
    my $fields = () = /<(input|select|textarea|Controller)\b|\bregister\(\s*["'\'']/g;
    my $req    = () = /\brequired\b|\.min\(1|nonempty\(/g;
    my $multi  = ($rel =~ /step|wizard|stepper/i) ? "true" : "false";
    my $stepper= (/<Stepper\b|<Steps\b|currentStep|activeStep/) ? "true" : "false";
    my $draft  = (/autosave|useAutoSave|draft|localStorage\.setItem/) ? "true" : "false";
    my $fid = "form:$rel";
    printf("N\t%s\tform\t%s\t%s\t{\"fields\":%d,\"required\":%d,\"multi\":%s,\"stepper\":%s,\"draft\":%s}\n",
      $fid, "form in $rel", $rel, $fields, $req, $multi, $stepper, $draft);
    print "E\t$id\t$fid\trenders\t{}\n";
  }
' -- $FILES > "$OUTDIR/.ux_scan_rows.tsv" 2>/dev/null || true

# Fold rows -> {meta,nodes,edges}. Import edges are resolved to file ids by suffix match in the
# skill's normalize step (graph-model.md); here we keep them raw but deduplicated.
jq -Rn --arg target "$TARGET" --arg n "$NFILES" '
  [ inputs | select(length>0) | split("\t") ] as $rows
  | ( [ $rows[] | select(.[0]=="N" and .[2]!="_navmeta") ]
      | map({id:.[1], kind:.[2], label:(.[3]//""), file:.[4], meta:(try (.[5]|fromjson) catch {})})
      | unique_by(.id) ) as $nodes
  | ( [ $rows[] | select(.[0]=="E") ]
      | map({from:.[1], to:.[2], type:.[3], meta:(try (.[4]|fromjson) catch {})})
      | unique_by("\(.from)|\(.to)|\(.type)") ) as $edges
  | { meta: {
        target: $target, files_scanned: ($n|tonumber),
        generated_at: (now | todateiso8601),
        note: "approximate: regex scan, not an AST"
      },
      nodes: $nodes, edges: $edges,
      stats: {
        nodes: ($nodes|length), edges: ($edges|length),
        screens: ([$nodes[]|select(.kind=="screen")]|length),
        containers: ([$nodes[]|select(.kind=="container")]|length),
        forms: ([$nodes[]|select(.kind=="form")]|length),
        entities: ([$edges[]|select(.to|startswith("data-entity:"))|.to]|unique|length)
      } }
' "$OUTDIR/.ux_scan_rows.tsv" > "$OUT"

rm -f "$OUTDIR/.ux_scan_rows.tsv"
SCREENS="$(jq -r '.stats.screens' "$OUT")"; EDGES="$(jq -r '.stats.edges' "$OUT")"
echo "ux-graph-scan: $NFILES files -> $OUT ($SCREENS screens, $EDGES edges) [approximate]"
