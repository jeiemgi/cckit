#!/usr/bin/env bash
# shellcheck shell=bash
# forge-none.sh — the forge provider when there is none (E537.2). Every forge_* call refuses with one
# line naming the verb that needs a forge (forge_need), rc 1. Nothing is silent and nothing returns 0.
# errors: strict — every function is rc 1
_forge_none() { forge_need; }
forge_api()           { _forge_none; }
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
