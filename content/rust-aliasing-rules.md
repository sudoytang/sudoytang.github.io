+++
title = "从C语言理解Rust Aliasing Rule"
date = 2025-10-24
description = "从 C 语言的 restrict 关键字和 memcpy/memmove 区别出发，理解 Rust 的 aliasing rule 如何帮助编译器进行更激进的优化。"
weight = 0

[taxonomies]
tags = ["Rust", "编译优化", "Memory Aliasing"]
categories = ["教程/笔记"]

[extra]
series = "Rust 编程漫谈"
toc = true
+++

## 前言

在学习 Rust 的过程中，我们经常听说 Rust 的借用检查器（borrow checker）不仅保证了内存安全，还能帮助编译器做出更激进的优化。
Prof. Baochun Li 在 ECE 1724 Rust 课程的《Lifetimes》Lecture 中提到了 Aliasing，并举了以下例子：

```rust
fn compute(input: &u32, output: &mut u32) {
    if *input > 10 {
        *output = 1;
    }
    if *input > 5 {
        *output *= 2;
    }
    // `*output` will be `2` if `input > 10`
}
```

他从可优化性的角度解释了 aliasing 假设对编译优化的影响。然而，对于被 borrow checker 保护得太好的 Rust 使用者来说，这段代码的可优化性似乎是理所当然的——毕竟借用规则不允许同时存在可变引用和不可变引用。这反而让人有点摸不着头脑：这和优化有什么关系？

要真正理解这个问题，我们需要回到 C 语言，看看在没有借用检查的世界里，编译器面临着怎样的困境。本文将从 C 语言的 aliasing 问题出发，逐步理解 Rust 的 aliasing rule 为编译器带来的价值。

## C语言中的 Aliasing Rule

### 什么是 Aliasing？

**Aliasing（别名）** 指的是两个或多个指针指向同一块内存区域的情况。当函数接收多个指针参数时，因为这些指针可能来自任何地方，编译器通常无法确定这些指针是否会指向重叠的内存，这就是 **pointer aliasing problem**。

一个经典的例子是 C 标准库中的 `memcpy` 和 `memmove`：

```c
void *memcpy(void *restrict dest, const void *restrict src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
```

注意到它们的函数签名有一个关键区别：`memcpy` 的参数带有 `restrict` 关键字，而 `memmove` 没有。

- **`memcpy`**：假设源和目标内存区域**不重叠**（no-alias），可以做激进优化（如并行拷贝、向量化）
- **`memmove`**：允许源和目标内存区域**重叠**（may-alias），必须小心处理拷贝顺序

这两个函数存在的原因正是因为 aliasing 的情况不同，需要不同的实现策略。

### 一个具体的例子

让我们把前面的 Rust 例子翻译成 C 语言，看看编译器会生成什么样的代码：

```c
// 版本1：不带 restrict
void compute(const unsigned int *input, unsigned int *output) {
    if (*input > 10) {
        *output = 1;
    }
    if (*input > 5) {
        *output *= 2;
    }
}
```

在这个版本中，编译器**不知道** `input` 和 `output` 是否指向同一块内存。因此它必须保守地假设它们**可能**指向同一地址。

让我们看看编译器会做什么（使用 `gcc -O2` 编译）：

```asm
compute:
        mov     eax, DWORD PTR [rdi]    ; unsigned temp = *arg0;
        cmp     eax, 10                 ; 
        jle     .L2                     ; if (temp > 10) {
        mov     DWORD PTR [rsi], 1      ;   *arg1 = 1;
        mov     eax, DWORD PTR [rdi]    ;   temp = *arg0;   // 注意：这里重新从内存取了值
.L2:                                    ; }
        cmp     eax, 5                  ; 
        jle     .L1                     ; if (temp > 5) {
        sal     DWORD PTR [rsi]         ;   *arg2 <<= 1;
.L1:                                    ; }
        ret                             ; return;
```

注意关键的一点：`*input` 被**读取了两次**（第 6 行再次从 `[rdi]` 读取）。

**为什么？** 因为编译器担心 `input` 和 `output` 可能指向同一地址。如果它们是同一个指针，那么第一个 `if` 块中的 `*output = 1` 就改变了 `*input` 的值！因此，第二个 `if` 必须重新读取 `*input` 的值，不能直接使用之前读取的值。

这就是 aliasing 带来的性能损失：编译器不得不生成保守的代码。

### restrict 关键字：告诉编译器"不会有别名"

C99 引入了 `restrict` 关键字，它是程序员向编译器做出的**承诺**：这个指针指向的内存区域在函数执行期间不会通过其他指针访问。

```c
// 版本2：带 restrict
void compute_restrict(const unsigned int *restrict input, 
                      unsigned int *restrict output) {
    if (*input > 10) {
        *output = 1;
    }
    if (*input > 5) {
        *output *= 2;
    }
}
```

现在我们只是在函数签名上加了 `restrict`，函数体完全相同。再看编译结果（`gcc -O2`）：

```asm
compute_restrict:
        mov     eax, DWORD PTR [rdi]    ; unsigned temp = *arg0;  // 注意：只读取一次arg0
        cmp     eax, 10                 ; 
        jg      .L8                     ; if (temp > 10) goto L8;
        cmp     eax, 5                  ; 
        jg      .L9                     ; if (temp > 5) goto L9;
        ret                             ;   return;
.L8:                                    ; L8:
        mov     eax, 2                  ; temp = 2;  // 注意：这里直接得到 *arg1 = 1 * 2;
        mov     DWORD PTR [rsi], eax    ; *arg1 = temp;
        ret                             ; return;
.L9:                                    ; L9:
        mov     eax, DWORD PTR [rsi]    ; temp = *arg1;
        add     eax, eax                ; temp *= 2;
        mov     DWORD PTR [rsi], eax    ; *arg1 = temp;
        ret                             ; return;
```

对比两个版本，区别非常明显：

1. **`*input` 只被读取一次**（第 1 行 `mov eax, DWORD PTR [rdi]`）：编译器知道 `*output = 1` 不会影响 `*input` 的值，可以在之后的比较中继续使用寄存器 `eax` 中的值
2. **更激进的优化**：当 `*input > 10` 时（`.L8` 分支），编译器推导出最终结果是 `2`，直接将常量 `2` 赋值并写入 `*output`，而不是先写 `1` 再乘以 `2`

这就是 `restrict` 关键字的威力：它让编译器能够根据 no-alias 假设进行更全面的优化。

## Rust的Aliasing Rule

现在我们回到 Rust。理解了 C 语言的问题后，Rust 的优势就显而易见了。

### 引用天然保证 No-Aliasing

Rust 对引用有严格的借用规则：

- **要么**有多个不可变引用（`&T`）
- **要么**有一个可变引用（`&mut T`）
- **但不能同时存在**

这个规则天然地保证了：**当存在可变引用时，不会有其他引用指向同一块内存**。这正是 no-aliasing 的定义！

让我们看看文章开头的 Rust 例子会被编译成什么：

```rust
pub fn compute(input: &u32, output: &mut u32) {
    if *input > 10 {
        *output = 1;
    }
    if *input > 5 {
        *output *= 2;
    }
}
```

编译结果 (`-C opt-level=3`)：

```asm
compute:
        mov     ecx, dword ptr [rdi]    ; unsigned input_val = *arg0;  // 注意：只读取一次
        mov     eax, 2                  ; unsigned result = 2; // 优化：预先计算出 *input > 10 时 *output = 2
        cmp     ecx, 10                 ; 
        ja      .LBB0_3                 ; if (input_val > 10) goto LBB0_3;
        cmp     ecx, 6                  ; 
        jb      .LBB0_4                 ; if (input_val <= 5) return;  // 两个条件都不满足，什么也不做
        mov     eax, dword ptr [rsi]    ; result = *arg1;              // 只满足第二个条件，乘2
        add     eax, eax                ; result *= 2;
.LBB0_3:                                ; LBB0_3:   // 如果 *input > 10 会跳到这里
        mov     dword ptr [rsi], eax    ; *arg1 = result;
.LBB0_4:                                ; 
        ret                             ; return;
```

可以看到，`*input` 同样只被读取一次（第 1 行，保存在 `ecx` 中），编译器还预先将常量 `2` 加载到 `eax` 中（第 2 行），为 `*input > 10` 的情况做准备。当 `*input > 10` 时，会跳转到 `.LBB0_3` 直接写入这个预先准备好的值。这和带 `restrict` 的 C 版本采用了相似的优化策略。

Rust 的借用规则让编译器确信 `input` 和 `output` 不会指向同一块内存，因此可以安全地进行激进优化。

### 裸指针：回到 C 的世界

那么，如果我们绕过借用检查器，使用裸指针（raw pointer）呢？

```rust
pub unsafe fn compute_raw(input: *const u32, output: *mut u32) {
    if *input > 10 {
        *output = 1;
    }
    if *input > 5 {
        *output *= 2;
    }
}
```

编译结果 (`-C opt-level=3`)：

```asm
compute_raw:
        mov     eax, dword ptr [rdi]    ; unsigned temp = *arg0;
        cmp     eax, 11                 ; 
        jae     .LBB1_1                 ; if (temp >= 11) goto LBB1_1;
        cmp     eax, 6                  ; 
        jae     .LBB1_3                 ; if (temp >= 6) goto LBB1_3;
.LBB1_4:                                ; 
        ret                             ; return;
.LBB1_1:                                ; LBB1_1:  // temp > 10 会跳到这里
        mov     dword ptr [rsi], 1      ; *arg1 = 1;
        mov     eax, dword ptr [rdi]    ; temp = *arg0;  // 注意：重新读取内存值
        cmp     eax, 6                  ; 
        jb      .LBB1_4                 ; if (temp <= 5) return;
.LBB1_3:                                ; LBB1_3:  // temp > 5 会跳到这里
        shl     dword ptr [rsi]         ; *arg1 <<= 1;
        ret                             ; return;
```

可以看到，在 `.LBB1_1` 分支中，`*input` 被读取了两次（第 1 行和第 10 行，都是 `mov eax, dword ptr [rdi]`）。这和不带 `restrict` 的 C 版本的行为一致：编译器必须在写入 `*output = 1` 之后重新读取 `*input`，因为它不能确定两个指针是否指向同一块内存。

这说明：**Rust 对裸指针没有 aliasing 假设**。编译器会保守地认为两个裸指针可能指向同一块内存。这是合理的，因为裸指针绕过了借用检查器，编译器无法保证它们的关系。

### Borrow Rules = 强化的 Aliasing Rules

通过对比可以看出：

| 语言/方式 | Aliasing 保证 | 编译器优化 |
|----------|--------------|-----------|
| C（普通指针） | ❌ 可能有 alias | 保守 |
| C（restrict） | ✅ 程序员承诺 no-alias | 激进 |
| Rust（引用） | ✅ 编译器强制 no-alias | 激进 |
| Rust（裸指针） | ❌ 可能有 alias | 保守 |

Rust 的借用规则本质上是一种**编译器强制执行的 aliasing rule**。它比 C 的 `restrict` 更强大，因为：

1. **静态检查**：违反规则会在编译时被发现，而不是运行时未定义行为
2. **自动推导**：编译器自动知道引用满足 no-alias，不需要程序员手动标注
3. **全局保证**：规则在整个程序中强制执行，而 `restrict` 只是局部承诺

这就是为什么 Rust 的 borrow checker 不仅保证了内存安全，还能带来性能优势——它为编译器提供了更多的优化信息。

## Rust Reference 怎么写的？

Rust 官方文档在 [Undefined Behavior](https://doc.rust-lang.org/reference/behavior-considered-undefined.html#r-undefined.alias) 一节中明确列出了关于 aliasing 的规则。

值得注意的是，**Rust 的 pointer aliasing rule 仍在演进中**。目前 Rust 团队正在通过 [Stacked Borrows](https://github.com/rust-lang/unsafe-code-guidelines/blob/master/wip/stacked-borrows.md) 和 [Tree Borrows](https://perso.crans.org/vanille/treebor/) 等模型来形式化这些规则。

但对于涉及**引用**的情况，规则是明确的：

> **产生以下情况的引用是未定义行为：**
> - 一个可变引用（`&mut T`）与任何其他指向相同内存的引用（无论可变或不可变）同时存活
> - 一个不可变引用（`&T`）与指向相同内存的可变引用同时存活

这些规则确保了：
1. **独占性**：`&mut T` 保证独占访问，编译器可以假设没有其他路径访问这块内存
2. **不变性**：`&T` 保证数据不会被修改，编译器可以缓存读取的值

编译器正是基于这些保证来进行优化的。违反这些规则（通常通过 `unsafe` 代码）会导致未定义行为，编译器生成的优化代码可能产生意外结果。

## 题外话：C++ 的 Strict Aliasing Rule

C++ 还有另一种形式的 aliasing rule，称为 **strict aliasing rule**（严格别名规则）。它关注的是**类型**而不是指针本身。

简单来说，C++ 的 strict aliasing rule 规定：**编译器可以假设不同类型的指针不会指向重叠的内存**（除了一些例外，如 `char*` 可以指向任何类型）。

看一个具体的例子：

```cpp
int get_value(int *p, float *q) {
    *p = 42;
    *q = 3.14f;
    return *p;
}
```

直觉上，如果 `p` 和 `q` 指向同一块内存，这个函数应该返回 `3.14f` 的位表示（一个整数，通常是 `1078523331`）。但实际上，编译器会基于 strict aliasing rule 进行优化：

```asm
get_value:
        mov     DWORD PTR [rdi], 42         ; *arg0 = 42;
        mov     eax, 42                     ; int temp = 42;
        mov     DWORD PTR [rsi], 0x4048f5c3 ; *arg1 = 3.14000010f
        ret                                 ; return temp;  // 这里编译器返回了42，而没有重新取arg0指向的值
```

注意最后一行：编译器**直接返回常量 `42`**，而不是重新读取 `*p` 的值。因为编译器假设 `int*` 和 `float*` 不会指向同一块内存，所以认为 `*q = 3.14f` 不会影响 `*p` 的值。

如果我们真的让 `p` 和 `q` 指向同一块内存：

```cpp
int value = 0;
int result = get_value(&value, reinterpret_cast<float*>(&value));
// result == 42，而不是 3.14f 的位表示！
// value 的内存中存储的是 3.14f 的位表示，但函数返回了 42
```

这是一个违反直觉的结果：内存中的值已经被改变了，但函数返回的却是旧值。这就是 strict aliasing rule 导致的未定义行为——编译器的优化假设被违反了。

这是一种基于**类型的 aliasing rule**，与我们之前讨论的基于**可变性和独占性的 aliasing rule**（Rust/C restrict）不同。两者的目标都是给编译器更多优化空间，但约束的角度不同：

- **C/Rust 的 restrict/borrow**：关注同一类型的多个指针是否重叠
- **C++ 的 strict aliasing**：关注不同类型的指针是否重叠

Rust 也有类似的规则（不同类型的引用不应指向同一内存），但由于 Rust 的类型系统和借用检查器的限制，在安全代码中很难违反这个规则。

## 总结

通过从 C 语言的 `restrict` 关键字出发，我们理解了 aliasing 对编译器优化的影响：

1. **Aliasing 是性能杀手**：当编译器不确定两个指针是否重叠时，必须生成保守的代码
2. **C 的 `restrict`**：程序员手动承诺 no-alias，但没有编译时检查
3. **Rust 的引用**：编译器通过借用规则强制保证 no-alias，自动获得优化
4. **Rust 的裸指针**：和 C 的普通指针一样，编译器保守处理

Rust 的借用检查器本质上是**把 aliasing rule 编码到类型系统中**，在保证内存安全的同时，也为编译器提供了丰富的优化信息。这是 Rust "零成本抽象"理念的一个完美体现：安全的代码也是高效的代码。

---

**参考资料**：
- [Rust Reference: Behavior considered undefined](https://doc.rust-lang.org/reference/behavior-considered-undefined.html)
- [The Rustonomicon: Aliasing](https://doc.rust-lang.org/nomicon/aliasing.html)
- [C99 Standard: The restrict type qualifier](https://en.cppreference.com/w/c/language/restrict)
- [Stacked Borrows: An Aliasing Model For Rust](https://github.com/rust-lang/unsafe-code-guidelines/blob/master/wip/stacked-borrows.md)
