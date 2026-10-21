// @author ixxxxoooo
// IDE 实验室的多语言样例(I0):首批 tree-sitter 语言各一份,覆盖注释、字符串、数字、关键字、类型、函数、属性/标签等语法类别,
// 用于 I5 的高亮快照测试与「不支持语言回退 SimpleLexer」验证。

import Foundation

extension DemoIDELab {
    /// 文件名 → 内容(文件名即扩展名所属语言)。
    static let languageSamples: [(name: String, text: String)] = [
        ("sample.swift", """
        // 订单服务
        import Foundation

        @MainActor
        final class OrderService: Sendable {
            private(set) var total: Double = 0
            let tax = 0.13

            /// 计算含税总价。
            func checkout(_ items: [Item]) async throws -> Double {
                guard !items.isEmpty else { throw OrderError.empty }
                total = items.reduce(0) { $0 + $1.price } * (1 + tax)
                return total
            }
        }
        """),
        ("sample.ts", """
        // 用户仓库
        export interface User { id: number; name: string; tags?: string[] }

        export class UserRepo {
          private cache = new Map<number, User>();
          async find(id: number): Promise<User | undefined> {
            if (this.cache.has(id)) return this.cache.get(id);
            const res = await fetch(`/api/users/${id}`);
            return res.ok ? ((await res.json()) as User) : undefined;
          }
        }
        """),
        ("sample.tsx", """
        // 页头组件
        import React from "react";

        type Props = { title: string; count?: number };

        export function Header({ title, count = 0 }: Props) {
          return (
            <header className="app-header" data-count={count}>
              <h1>{title}</h1>
              {count > 0 && <span>{count} 条未读</span>}
            </header>
          );
        }
        """),
        ("sample.js", """
        // 防抖
        const debounce = (fn, wait = 200) => {
          let timer = null;
          return (...args) => {
            clearTimeout(timer);
            timer = setTimeout(() => fn.apply(this, args), wait);
          };
        };
        module.exports = { debounce, VERSION: "1.0.0", RATIO: 0.75 };
        """),
        ("sample.py", """
        # 统计词频
        from collections import Counter
        from dataclasses import dataclass

        @dataclass
        class Report:
            words: int
            top: list[str]

        def analyze(text: str, limit: int = 3) -> Report:
            \"\"\"返回词数与出现最多的词。\"\"\"
            counts = Counter(text.split())
            return Report(sum(counts.values()), [w for w, _ in counts.most_common(limit)])
        """),
        ("sample.go", """
        // 简单的限流器
        package limiter

        import (
        \t"sync"
        \t"time"
        )

        type Bucket struct {
        \tmu     sync.Mutex
        \ttokens int
        \tlast   time.Time
        }

        func (b *Bucket) Take() bool {
        \tb.mu.Lock()
        \tdefer b.mu.Unlock()
        \tif b.tokens > 0 { b.tokens--; return true }
        \treturn false
        }
        """),
        ("sample.rs", """
        // 解析键值对
        use std::collections::HashMap;

        #[derive(Debug, Clone)]
        pub struct Config { pub values: HashMap<String, String> }

        impl Config {
            pub fn parse(input: &str) -> Result<Self, String> {
                let mut values = HashMap::new();
                for line in input.lines() {
                    let (k, v) = line.split_once('=').ok_or("缺少 =")?;
                    values.insert(k.trim().to_string(), v.trim().to_string());
                }
                Ok(Self { values })
            }
        }
        """),
        ("sample.c", """
        /* 计算数组和 */
        #include <stdio.h>
        #define COUNT 4

        static int sum(const int *values, size_t n) {
            int total = 0;
            for (size_t i = 0; i < n; i++) total += values[i];
            return total;
        }

        int main(void) {
            int data[COUNT] = {1, 2, 3, 4};
            printf("sum=%d\\n", sum(data, COUNT));
            return 0;
        }
        """),
        ("sample.cpp", """
        // 简单的 LRU 缓存
        #include <list>
        #include <unordered_map>

        template <typename K, typename V>
        class LruCache {
        public:
            explicit LruCache(std::size_t capacity) : capacity_(capacity) {}
            void put(const K &key, V value) {
                items_.emplace_front(key, std::move(value));
                index_[key] = items_.begin();
                if (items_.size() > capacity_) { index_.erase(items_.back().first); items_.pop_back(); }
            }
        private:
            std::size_t capacity_;
            std::list<std::pair<K, V>> items_;
            std::unordered_map<K, typename std::list<std::pair<K, V>>::iterator> index_;
        };
        """),
        ("sample.json", """
        {
          "name": "ide-lab",
          "version": "1.0.0",
          "private": true,
          "scripts": { "build": "tsc -p .", "test": "vitest run" },
          "limits": { "files": 10000, "ratio": 0.75, "enabled": true, "extra": null }
        }
        """),
        ("sample.yaml", """
        # 部署配置
        name: ide-lab
        replicas: 3
        image: "registry.example.com/ide-lab:1.0.0"
        env:
          - name: MODE
            value: production
          - name: RATIO
            value: 0.75
        enabled: true
        """),
        ("sample.toml", """
        # 项目配置
        [package]
        name = "ide-lab"
        version = "1.0.0"
        edition = "2024"

        [dependencies]
        serde = { version = "1", features = ["derive"] }
        retries = 3
        verbose = true
        """),
        ("sample.md", """
        # IDE 实验室

        ## 说明

        这是一份 **Markdown** 样例,含 *斜体*、`行内代码` 与 [链接](https://example.com)。

        - [x] 已完成
        - [ ] 待办

        ```swift
        let answer = 42
        ```

        > 引用块
        """),
        ("sample.html", """
        <!-- 页面骨架 -->
        <!doctype html>
        <html lang="zh-CN">
          <head><meta charset="utf-8"><title>IDE 实验室</title></head>
          <body class="home" data-theme="paper">
            <main id="app"><h1>你好</h1><a href="https://example.com">链接</a></main>
            <script>console.log("ready", 42);</script>
          </body>
        </html>
        """),
        ("sample.css", """
        /* 主题变量 */
        :root { --accent: #d4592a; --radius: 8px; }

        .app-header > h1:hover {
          color: var(--accent);
          margin: 0 auto;
          font: 600 14px/1.4 system-ui, sans-serif;
          border-radius: var(--radius);
        }

        @media (max-width: 640px) { .app-header { display: none; } }
        """),
        ("sample.sh", """
        #!/usr/bin/env bash
        # 清理构建目录
        set -euo pipefail

        BUILD_DIR="${1:-build}"
        if [[ -d "$BUILD_DIR" ]]; then
          echo "清理 $BUILD_DIR"
          rm -rf "$BUILD_DIR"
        fi
        for n in 1 2 3; do echo "第 $n 次"; done
        """),
        // 不在首批语言里:用来验证回退到 SimpleLexer 不崩溃
        ("sample.lua", """
        -- 不支持的语言:回退到简易词法
        local function greet(name)
          return "你好," .. name
        end
        print(greet("IDE"))
        """),
    ]
}
