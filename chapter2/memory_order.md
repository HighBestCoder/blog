# C++六种内存序简明总结

## 1. memory_order_relaxed
- 仅保证原子性，无同步保证
- 允许任意重排序，最轻量级

## 2. memory_order_acquire
- **读不前**：后续操作不能被重排到此读取操作之前
- 仅用于load操作(读取)
- 能看到匹配release写入的内容

## 3. memory_order_release
- **写不后**：之前操作不能被重排到此写入操作之后
- 仅用于store操作(写入)
- 使此前写入对acquire读取可见

## 4. memory_order_acq_rel
- **既读不前又写不后**
- **只能用于RMW操作**：fetch_add、exchange、compare_exchange等
- 不能用于简单的load或store

## 5. memory_order_seq_cst
- 提供全局一致顺序，最强保证
- 所有线程看到相同操作顺序
- 包含acq_rel全部特性
- 是默认内存序

## 6. memory_order_consume
- 弱化版acquire，仅对数据依赖提供保证
- 标准委员会建议避免使用
- 实际上大多被实现为acquire

## 记忆口诀
- relaxed：无约束，性能最佳
- acquire：**读不前**，读取同步点
- release：**写不后**，写入同步点
- acq_rel：**双向保证，仅RMW**
- seq_cst：全序一致，最强保证
- consume：仅依赖保证，避免使用

# acq_rel重点讲一下

# happens-before 关系与 memory_order_acq_rel 详解

## happens-before 的语义

"happens-before"是C++内存模型中的关键概念，它正式定义了操作间的顺序保证：

- 如果操作A happens-before 操作B，则：
  1. A的所有内存效果对B可见
  2. A在逻辑上先于B执行完成

happens-before不是简单的时间顺序，而是一种保证内存访问可见性的形式化关系。

## memory_order_acq_rel 与可见性保证

使用 `memory_order_acq_rel` 确实创建了 happens-before 关系，但**有条件的**，不是无条件的全局保证：

### 正确的理解

当线程A执行带 `memory_order_acq_rel` 的RMW操作X时：

1. 线程A中，X之前的所有写操作 happens-before X（release部分）
2. 如果线程B通过**至少为acquire**的读操作观察到X的结果
3. 那么线程A中X之前的所有写入 happens-before 线程B中观察到X后的操作

### 示例解析

```cpp
// 线程A
data = 42;                                  // 普通写入
x.fetch_add(1, std::memory_order_acq_rel); // RMW操作X

// 线程B
if (x.load(std::memory_order_acquire) == 1) { // 看到X的效果
    // 这里可以保证看到 data = 42
    assert(data == 42); // 永远不会触发
}

// 线程C - 没有适当同步
if (x.load(std::memory_order_relaxed) == 1) { // 使用relaxed
    assert(data == 42); // 可能会触发！没有建立happens-before关系
}
```

### 重要限制

1. **需要同步配对**：
   - `acq_rel`操作必须与其他线程的`acquire`(或更强)操作配对
   - 第二个线程必须实际观察到`acq_rel`操作的结果

2. **针对性同步**：
   - 只在特定参与同步的线程间建立happens-before关系
   - 不是对所有线程的全局保证

3. **传递性**：
   - happens-before关系具有传递性
   - 如果A happens-before B且B happens-before C，则A happens-before C

总结：`memory_order_acq_rel`前的可见性**不是一定保证的**，而是有条件的保证—只有当另一个线程使用适当的内存序(至少为acquire)观察到该操作的效果时才成立。