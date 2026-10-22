// @author ixxxxoooo
// 各语言 tree-sitter 语法入口(只声明,实现在各语法目录的 parser.c)。
#ifndef TREESITTERGRAMMARS_H
#define TREESITTERGRAMMARS_H
#include "tree_sitter/api.h"

const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_html(void);
#endif
