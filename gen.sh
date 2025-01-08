#!/bin/bash

# 创建目录结构
mkdir -p _data
mkdir -p intro
mkdir -p chapter1/section1
mkdir -p chapter1/section2
mkdir -p chapter1/section3

# 生成前言
cat <<EOL > intro/intro.md
---
title: 前言
order: 1
---

## 前言

欢迎阅读本书！本书将带你深入了解 LevelDB 的源码实现。

### 内容简介
- 第一章：LevelDB 的基本概念
- 第二章：LevelDB 的核心组件
- 第三章：LevelDB 的源码分析

希望你能从中受益！
EOL

# 生成第一章
cat <<EOL > chapter1/chapter1.md
---
title: 第一章：LevelDB 的基本概念
order: 2
---

## 第一章：LevelDB 的基本概念

本章将介绍 LevelDB 的基本概念，包括其设计思想、核心组件和使用场景。
EOL

# 生成第一章第一节
cat <<EOL > chapter1/section1/section1.md
---
title: 第一节：LevelDB 的设计思想
order: 1
---

## 第一节：LevelDB 的设计思想

LevelDB 的设计思想基于 LSM-Tree（Log-Structured Merge-Tree），具有高效的写入性能。
EOL

# 生成第一章第二节
cat <<EOL > chapter1/section2/section2.md
---
title: 第二节：LevelDB 的核心组件
order: 2
---

## 第二节：LevelDB 的核心组件

LevelDB 的核心组件包括 MemTable、SSTable 和 Compaction。
EOL

# 生成第一章第三节
cat <<EOL > chapter1/section3/section3.md
---
title: 第三节：LevelDB 的使用场景
order: 3
---

## 第三节：LevelDB 的使用场景

LevelDB 适用于需要高性能键值存储的场景，如缓存、日志存储等。
EOL

# 生成 menu.yml
cat <<EOL > _data/menu.yml
- title: 前言
  url: /intro/
  order: 1

- title: 第一章：LevelDB 的基本概念
  url: /chapter1/
  order: 2
  children:
    - title: 第一节：LevelDB 的设计思想
      url: /chapter1/section1/
      order: 1
    - title: 第二节：LevelDB 的核心组件
      url: /chapter1/section2/
      order: 2
    - title: 第三节：LevelDB 的使用场景
      url: /chapter1/section3/
      order: 3
EOL

# 输出完成信息
echo "书籍内容已生成！目录结构如下："
find . -type d
