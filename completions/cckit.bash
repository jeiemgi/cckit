# bash completion for cckit. Enable with:  source <(cckit completions bash)
# Verbs are pulled live from `cckit commands`, so this never drifts from the dispatcher.
_cckit() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "${COMP_CWORD}" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$(cckit commands 2>/dev/null)" -- "$cur") )
  fi
}
complete -F _cckit cckit
