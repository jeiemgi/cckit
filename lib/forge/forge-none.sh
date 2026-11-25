#!/usr/bin/env bash
# shellcheck shell=bash
# forge-none.sh — the forge provider when there is none (E537.2). Every forge_* call refuses with one
# line naming the verb that needs a forge (forge_need), rc 1. Nothing is silent and nothing returns 0.
# errors: strict — every function is rc 1
_forge_none() { forge_need; }
forge_api()           { _forge_none; }
forge_rest()          { _forge_none; }
forge_graphql()       { _forge_none; }
forge_issue_view()    { _forge_none; }
forge_issue_create()  { _forge_none; }
forge_issue_close()   { _forge_none; }
forge_issue_comment() { _forge_none; }
forge_issue_label()   { _forge_none; }
forge_issue_list()    { _forge_none; }
forge_pr_open()       { _forge_none; }
forge_pr_view()       { _forge_none; }
forge_pr_merge()      { _forge_none; }
forge_pr_list()       { _forge_none; }
forge_cli_present()   { command -v gh >/dev/null 2>&1; }
forge_cli_version()   { gh --version 2>/dev/null | sed -n 1p | awk '{print $3}'; }
forge_login()         { if command -v gh >/dev/null 2>&1; then gh auth login --git-credential-helper; else echo "cckit: no gh installed — put a token in GH_TOKEN, or install gh and run gh auth login" >&2; return 1; fi; }
forge_login_scope()   { _forge_none; }
forge_token_scopes()  { _forge_none; }
