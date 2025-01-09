---
title: Linux性能调优：示例
order: 1
---

# 记一次深入内核的数据库抖动排查

**作者**：Yriuns
**链接**：https://zhuanlan.zhihu.com/p/14709946806
**来源**：知乎
**著作权声明**：著作权归作者所有。商业转载请联系作者获得授权，非商业转载请注明出处。

## 背景
我在公司参与一款分布式关系型数据库 (C++)的研发，目前生产环境已经有几百个集群，今天的主角就是其中一个核心业务。

一个集群有多个节点，跑在 k8s 上。而这个业务各个 pod 所在的宿主机正好都只分配了 1 个 pod，且已经做了 CPU 绑核处理，照理说应该非常稳定。然而每天都会发生 1 - 2 次抖动，现象是：
- 不论读请求还是写请求，不管是处理用户请求的线程还是底层 raft 相关的线程，都 hang 住了数百毫秒。
- 慢请求日志里显示处理线程没有 suspend ，wall time 很大，但真正耗费的 CPU time^{[1]} 很小。
- 且抖动发生时不论是容器还是宿主机，CPU 使用率都非常低。

## 内核调度？
事实上，这个集群之所以进行 CPU 绑核，就是因为之前定位过另一个抖动问题：在未绑核的情况下，很容易触发 cgroup 限流（会编程的八爪鱼：Kubernetes 迁移踩坑：CPU 节流 ）。而我们的生产环境是完全不超售的，自然就为了稳定性选择绑核。

有了上次的踩坑经验，这次我第一时间就怀疑是内核调度的锅。于是写了一个简单的 ticker，不停地干 10ms 活再 sleep 10ms，一个 loop 内如果总耗时 > 25ms 就认为发生了抖动，输出一些 CPU、调度的信息。分别启动了 3 个实例：
- ticker 运行在容器内，不绑核。
- ticker 运行在容器内，绑核。
- ticker 运行在宿主机上，绑核。

都出现了不同程度的抖动，其中 2 是最抖的，调度延迟经常 > 5ms。但它抖动的频率远高于我们的数据库进程，而抖动幅度又远小于，还是不太相似。

既然如此，决定还是从应用进程入手，让 GPT 写了个脚本，在容器内不停地通过 perf sched 抓取操作系统的调度事件，然后等待抖动复现。复现后利用 perf sched latency 看看各个线程的调度延迟以及时间点：
```
$ perf sched latency
...
:211677:211677        |    160.391 ms |     2276 | avg:    2.231 ms | max:  630.267 ms | max at: 1802765.259076 s
:211670:211670        |    137.200 ms |     2018 | avg:    2.356 ms | max:  591.592 ms | max at: 1802765.270541 s
...
```
这俩的 max at 时间点是接近的，max 抖动的值和数据库的慢请求日志也能对上。说明数据库的抖动就是来自于内核调度延迟！但为什么这么慢呢？

根据 max at 的时间点在 perf sched script 里找原始的事件：
```
rpchandler   114 [011] 1802764.628809:       sched:sched_wakeup: rpchandler:211677 [120] success=1 CPU:075
rpchandler   112 [009] 1802765.259076:       sched:sched_switch: rpchandler:211674 [120] T ==> rpchandler:211677 [120]
rpchandler   115 [009] 1802765.259087: sched:sched_stat_runtime: comm=rpchandler pid=211677 runtime=12753 [ns] vruntime=136438477015677 [ns]
```
由于是在容器内抓的，第 2 列的数字是在容器内的线程 id，需要与宿主机上的线程 id 做一个换算：115 对应 211677，112 对应 211674。意思是说 tid 114 把 tid 115 唤醒了（在 075 核上），但过了 500 + ms 后，009 核上的 tid 112 运行完才再次调度 tid 115。

注意：缺少了 tid 115 从 075 被 migrate 到 009 上的事件。这意味着 009 核出于某些原因一直不运行 tid 115，再往前看看 009 这个核在干嘛，发现一直在调度时间轮线程。
```
TimeWheel.Routi    43 [009] 1802765.162014: sched:sched_stat_runtime: comm=TimeWheel.Routi pid=210771 runtime=2655 [ns] vruntime=136438438256234 [ns]
TimeWheel.Routi    43 [009] 1802765.162015:       sched:sched_switch: TimeWheel.Routi:210771 [120] D ==> swapper/9:0 [120]
         swapper     0 [009] 1802765.163067:       sched:sched_wakeup: TimeWheel.Routi:210771 [120] success=1 CPU:009
         swapper     0 [009] 1802765.163069:       sched:sched_switch: swapper/9:0 [120] S ==> TimeWheel.Routi:210771 [120]
TimeWheel.Routi    43 [009] 1802765.163073: sched:sched_stat_runtime: comm=TimeWheel.Routi pid=210771 runtime=4047 [ns] vruntime=136438438260281 [ns]
TimeWheel.Routi    43 [009] 1802765.163074:       sched:sched_switch: TimeWheel.Routi:210771 [120] D ==> swapper/9:0 [120]
         swapper     0 [009] 1802765.164129:       sched:sched_wakeup: TimeWheel.Routi:210771 [120] success=1 CPU:009
         swapper     0 [009] 1802765.164131:       sched:sched_switch: swapper/9:0 [120] S ==> TimeWheel.Routi:210771 [120]
TimeWheel.Routi    43 [009] 1802765.164135: sched:sched_stat_runtime: comm=TimeWheel.Routi pid=210771 runtime=3616 [ns] vruntime=136438438263897 [ns]
TimeWheel.Routi    43 [009] 1802765.164137:       sched:sched_switch: TimeWheel.Routi:210771 [120] D ==> swapper/9:0 [120]
         swapper     0 [009] 1802765.165187:       sched:sched_wakeup: TimeWheel.Routi:210771 [120] success=1 CPU:009
         swapper     0 [009] 1802765.165189:       sched:sched_switch: swapper/9:0 [120] S ==> TimeWheel.Routi:210771 [120]
```
于是有了一个“合理”的猜想：
- TimeWheel 由于干的活非常轻(2us)，sleep 时间(1ms)相对显得非常大，于是 vruntime 涨的很慢。
- 由于调度，rpchandler 线程到了 TimeWheel 所在的核上，它的 vruntime 在新核上属于很大的（即使迁移后会重新计算 vruntime）。
- cfs 调度器倾向于一直调度 TimeWheel 线程。

但同事注意到唤醒时间轮的都是 swapper，它只在 CPU 当时没有其他任务可调度的时候出现。又由于缺少了 075 到 009 的 migrate 事件，没法实锤 tid 115 是在 009 核上被耽误的，有可能 tid 115 就是一直在别的核上，直到 500ms 后才 migrate 到 009 上。那么 009 核没事干自然一直运行时间轮线程。

至于 migrate 事件的缺失，估计是容器里抓的调度事件有点问题，因此改到宿主机上再抓。

## 诡异的 SIGSTOP
把 perf sched 脚本在宿主机上跑起来之后，很快又等到了数据库抖动，但奇怪的是这次 perf sched latency 完全没问题，最大的调度延迟才 1ms。

难道错怪内核了，是我们自己代码有问题？不信邪，放弃了 perf sched lantency，用肉眼观察 tid 211677（容器里的 tid 115）的原始调度事件，发现某次切出后过了 689ms 才被 swapper 唤醒，和数据库观测到的延迟吻合。
```
rpchandler 211677 [067] 1889343.661328:       sched:sched_switch: rpchandler:211677 [120] T ==> swapper/67:0 [120]
          swapper     0 [067] 1889344.350873:       sched:sched_wakeup: rpchandler:211677 [120] success=1 CPU:067
```
但这个唤醒间隔不符合预期，每个 rpc handler 线程至少会以 50ms 的间隔醒来一次，查看其他线程的队列里是否有可以 stealing 的任务，所以这个线程一定是被耽误了。

注意到 211677 是以 T 状态切出的，这个状态的意思是 stopped by job control signal[2]，也就是有人给线程发 SIGSTOP 信号。收到这个信号的线程会被暂停，直到之后收到 SIGCONT 信号才会继续运行。

同事又看了看其他线程，发现都在这个时间点以 T 状态切出。可以推断有个什么外部进程在给所有线程发信号，用来抓取某些信息。结合之前 cgroup 限流的知识，很有可能就是这个进程发送了 SIGSTOP 后正好用尽了时间片被 cfs 调度器切出，过了几百毫秒后才重新执行，发送了 SIGCONT 信号。

接着就在这个时间点附近观察有没有什么可疑的进程，同事很快锁定了其中一个由安全团队部署的插件，因为在内网 wiki 里它的介绍是：进程监控。

于是我们询问安全团队该插件是否有发送 SIGSTOP 的行为，得到的答复是没有。我用 bpftrace 追踪了 do_signal，也并没有捕获到 SIGSTOP 信号。

但来都来了，我们死马当活马医关闭了该组件。结果，抖动消失了！

进一步从安全团队了解到该插件会利用 /proc 伪文件系统定时扫描宿主机上所有进程的 cpuset、comm、cwd 等信息，需要排查具体是插件的哪个行为导致了抖动。

安全团队修改代码，让插件记录每个扫描项的开始时间和结束时间，输出到日志中。这样数据库发生抖动后，我们只要对比扫描时间和抖动时间，就能锁定是哪个扫描项。

但等了好几天，都没有发生抖动，看来获取时间以及输出日志破坏了抖动的触发场景。不过从日志中我们发现读取 /proc/pid/environ 的耗时经常抖动至几百 ms，非常可疑。

因此我们去掉了日志，把机器分为两组：第 1 组只扫描 environ，第 2 组只去掉 environ。很快，第 1 组发生了抖动，而第 2 组则岁月静好。

至此，我们已经明确是读取 environ 导致的抖动。但仍然疑点重重：扫描 environ 为什么会导致抖动？扫描 environ 为什么会导致线程处于 T 状态？

## mmap_sem
暂且把 T 状态搁置，既然没有证据表明有人发 SIGSTOP，那么还能让这么多线程同时挂起的只有锁了，问问 GPT：读取 /proc/pid/environ 是否会有锁争用？

接着 google 下：proc "environ" mmap_sem 看到了这篇 blog：https://blog.csdn.net/Linux_Everything/article/details/102735790

对应的内核代码在这：https://elixir.bootlin.com/linux/v4.18/source/fs/proc/base.c#L887

意思是说，mmap_sem 是个和 VMA 相关的读写锁，粒度很大，facebook 的安全监控读 environ 的时候加 mmap_sem 读锁成功，然后由于时间片用完被调度出去了。而数据库运行过程中需要加写锁，就 block 住了，并且之后的读锁也都会被 block，直到安全监控重新调度后释放了读锁。

听起来非常的合理且符合我们的现象，那么就尝试在测试环境复现一下。

实现一个持续读取数据库进程 environ 的程序，利用 cgroup 给它 CPU 限额至一个较低的值（单核的 3%）。果然数据库频繁发生 100ms 以上的抖动，1 分钟大概会出现 2 次。如果把 CPU 限额取消，即使该程序疯狂读取 environ、跑满了 CPU，数据库也没有任何抖动！

找到了稳定复现的方式，问题就不难排查了。接下来只需要找到我们的数据库里哪个路径需要加 mmap_sem 的写锁。

利用 https://github.com/brendangregg/perf-tools/tree/master 里的 functrace 很轻易的找到了：::write 会调用 down_write。
```
Tracing "down_write"... Ctrl-C to end.
# tracer: function
#
#                              _-----=> irqs-off
#                             / _----=> need-resched
#                            | / _---=> hardirq/softirq
#                            || / _--=> preempt-depth
#                            ||| /     delay
#           TASK-PID   CPU#  ||||    TIMESTAMP  FUNCTION
#              | |       |   ||||       |         |
           <...>-218136 [069].... 17019438.716402: down_write <-do_truncate
           <...>-218136 [069].... 17019438.716405: down_write <-unmap_mapping_pages
           <...>-218136 [069].... 17019438.716406: down_write <-unmap_mapping_pages
           <...>-42098  [002].... 17019438.716413: down_write <-ext4_write_end 
```
而这里的 42098 线程恰好就是数据库的 raft 线程，它在落盘 raft log 时需要调用 ::write 与 ::sync。

因此，问题时序如下：
- 安全插件：调用 environ_read -> down_read。
- 数据库 raft 线程：调用 ::write -> down_write，阻塞。
- 数据库其他线程：page_fault -> down_read，阻塞。
- 由于 cgroup 限制，安全插件被 cfs 调度器切出。
- 安全插件重新执行，up_read 释放读锁。

## 剩余问题探究：perf sched 显示状态异常原因
至此，还有一个问题没解决：为啥 `perf sched` 显示数据库线程是 `T` 状态切出的？利用 `bpftrace` 看看。

```bash
#!/usr/bin/bpftrace

kprobe:finish_task_switch
/tid >= 41875 && tid <= 41896/
{
  printf("finish task switch by %d\n", tid);
  print(kstack(10));
}

kprobe:prepare_to_wait_exclusive
/tid >= 41875 && tid <= 41896/
{
  printf("prepare switch %d, state=%d\n", tid, arg2);
  print(kstack(10));
}

// Attach to the 'sched_switch' tracepoint
tracepoint:sched:sched_switch {
    if (args->prev_pid >= 41875 && args->prev_pid <= 41896) {
      printf("prev_comm=%s prev_pid=%d prev_prio=%d prev_state=%s ==> next_comm=%s next_pid=%d next_prio=%d\n",
            args->prev_comm, args->prev_pid, args->prev_prio,
            args->prev_state & 0x01? "S" :
            args->prev_state & 0x02? "D" :
            args->prev_state & 0x04? "T" :
            args->prev_state & 0x08? "t" :
            args->prev_state & 0x10? "X" :
            args->prev_state & 0x20? "Z" :
            args->prev_state & 0x40? "P" :
            args->prev_state & 0x80? "I" : "R",
            args->next_comm, args->next_pid, args->next_prio);
    }
}
```

不看不知道，一看吓一跳：我这 `state` 明明设置的是 `TASK_UNINTERRUPTIBLE = 0x02`，怎么最终显示的是 `T` 状态？

```
prepare switch 41887, state=2

        prepare_to_wait_exclusive+1
        __lock_sock+108
        lock_sock_nested+87
        tcp_sendmsg+25
        sock_sendmsg+79
        ____sys_sendmsg+491
        ___sys_sendmsg+124
        __sys_sendmsg+87
        do_syscall_64+91
        entry_SYSCALL_64_after_hwframe+101

prev_comm=rpchandler prev_pid=41887 prev_prio=120 prev_state=T ==> next_comm=swapper/68 next_pid=0 next_prio=120
```

对着我们使用的内核版本（`v4.18`）代码看看打印的 `prev_state` 是怎么取出来的：

```c
static inline long __trace_sched_switch_state(bool preempt, struct task_struct *p)
{
#ifdef CONFIG_SCHED_DEBUG
    BUG_ON(p!= current);
#endif /* CONFIG_SCHED_DEBUG */

    /*
     * Preemption ignores task state, therefore preempted tasks are always
     * RUNNING (we will not have dequeued if state!= RUNNING).
     */
    if (preempt)
        return TASK_REPORT_MAX;

    return 1 << task_state_index(p);
}

static inline unsigned int task_state_index(struct task_struct *tsk)
{
    unsigned int tsk_state = READ_ONCE(tsk->state);
    unsigned int state = (tsk_state | tsk->exit_state) & TASK_REPORT;

    BUILD_BUG_ON_NOT_POWER_OF_2(TASK_REPORT_MAX);

    if (tsk_state == TASK_IDLE)
        state = TASK_REPORT_IDLE;

    return fls(state);
}
```

`fls` 返回最高位 `1` 的序号（从 `1` 开始），这里 `0x02` 的 `fls` 就是 `2`，然后直接被左移了 `1` 位变成 `4`，然后通过 `state to char` 计算就变成了 `T`！

不敢相信内核里竟有如此低级的错误，找最新版的内核代码对比一下：

```c
static inline long __trace_sched_switch_state(bool preempt, struct task_struct *p)
{
    unsigned int state;

#ifdef CONFIG_SCHED_DEBUG
    BUG_ON(p!= current);
#endif /* CONFIG_SCHED_DEBUG */

    /*
     * Preemption ignores task state, therefore preempted tasks are always
     * RUNNING (we will not have dequeued if state!= RUNNING).
     */
    if (preempt)
        return TASK_REPORT_MAX;

    /*
     * task_state_index() uses fls() and returns a value from 0-8 range.
     * Decrement it by 1 (except TASK_RUNNING state i.e 0) before using
     * it for left shift operation to get the correct task->state
     * mapping.
     */
    state = task_state_index(p);

    return state? (1 << (state - 1)) : state;
}
```

还真不一样……`state > 0` 的时候，需要先 `-1` 再左移，而不是直接左移。这样如果 `fls` 返回了 `2`，`__trace_sched_switch_state` 返回的就会是 `1 << (2 - 1) = 2` ，也就是 `D`（不可中断）状态。

## 总结
- Linux 内核中每个进程有一个 `mmap_sem` 读写锁，保护 `vma` 相关的字段，粒度很大。
- 安全插件读取 `/proc/pid/environ` 扫描进程的环境变量，走到内核的 `environ_read` 函数，获取了 `mmap_sem` 读锁。安全插件通过 `cgroup` 设置了 `CPU quota`，在调用 `environ_read` 期间由于时间片用完被 `cfs` 调度器切出。
- 数据库 `raft` 线程会调用 `::write` 和 `::sync` 将 `raft log` 落盘，走到内核的 `ext4_write_end` 函数，需要获取 `mmap_sem` 写锁。由于安全插件还没放读锁，写锁被阻塞。
- 数据库的其他线程由于内存申请触发 `minor page fault`，需要获取 `mmap_sem` 读锁，也被阻塞。至此，数据库大量线程 `hang` 住。
- 安全插件重新被调度，释放读锁后抖动结束。
- `v4.18` 内核对线程状态的展示是错误的，实际是 `D`（不可中断）状态，但 `perf sched` 会展示为 `T`（停止）状态。

## 后记
这个问题最终能定位实属侥幸：如果内核展示的线程状态是准确的，那么 `perf sched script` 看到的就是一堆线程以 `D` 状态切出，排查方向就不会立刻锁定到外部进程上。

参考：
- ^CPU time 来自于 `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`;
- ^https://man7.org/linux/man-pages/man1/ps.1.html
