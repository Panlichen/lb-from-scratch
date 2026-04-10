# 这一行只是被注释掉的变量赋值示例，不会被 make 执行。
# 如果把前面的 # 去掉，`TARGET = xdp_lb` 就会把 TARGET 变量设为 xdp_lb。
# TARGET = xdp_lb

# 同理，这也是另一个可选的 TARGET 示例，目前不会生效。
# TARGET = packetdrop

# `=` 是 make 的递归展开变量赋值语法。
# 这里把当前要构建的程序前缀设为 xdp_liz。
# 后面很多变量和 target 名称都会从它派生出来。
TARGET = xdp_liz

# 这是一行纯注释，说明：
# 如果目标是 xdp_liz，通常除了 eBPF 程序外，还要额外构建 userspace 程序。
# 另外两个示例目标没有对应的 userspace 程序。
# For xdp_liz, make and also make user. The others don't have userspace programs

# `${TARGET:=_user}` 是 make 的变量替换写法。
# 它会把 TARGET 的值 `xdp_liz` 变成 `xdp_liz_user`。
# 因而 USER_TARGET 表示用户态程序的目标名。
USER_TARGET = ${TARGET:=_user}

# `${TARGET:=_kern}` 同样是变量替换。
# 它会把 `xdp_liz` 变成 `xdp_liz_kern`。
# 这是内核态 eBPF 程序的基础名字。
BPF_TARGET = ${TARGET:=_kern}

# `${BPF_TARGET:=.c}` 会在 BPF_TARGET 后面拼接 `.c`。
# 因而这里得到源文件名 `xdp_liz_kern.c`。
BPF_C = ${BPF_TARGET:=.c}

# `${BPF_C:.c=.o}` 是“后缀替换”语法：
# 把 BPF_C 中结尾的 `.c` 替换成 `.o`。
# 因而这里得到要产出的目标文件 `xdp_liz_kern.o`。
BPF_OBJ = ${BPF_C:.c=.o}

# `xdp` 是一个显式 target。
# 冒号右边的 `$(BPF_OBJ)` 是它的依赖，也就是 `xdp_liz_kern.o`。
# 当你直接运行 `make` 时，make 默认会选择文件里“第一个 target”作为入口，
# 所以这里默认入口就是 `xdp`。
xdp: $(BPF_OBJ)
	# recipe 行必须以 Tab 开头。
	# 这一行尝试先把网卡 eth0 上现有的 xdpgeneric XDP 程序解绑，
	# 避免重复 attach 时失败。
	bpftool net detach xdpgeneric dev eth0
	# 删除 bpffs 中旧的 pinned 对象；`-f` 表示即使文件不存在也不报错。
	rm -f /sys/fs/bpf/$(TARGET)
	# 把刚编译出来的 eBPF 对象文件加载进内核，并固定到 bpffs 路径上。
	bpftool prog load $(BPF_OBJ) /sys/fs/bpf/$(TARGET)
	# 把 pinned 的 eBPF 程序挂到 eth0 的 xdpgeneric hook 上。
	bpftool net attach xdpgeneric pinned /sys/fs/bpf/$(TARGET) dev eth0

# `user` 是另一个显式 target。
# 它本身不直接写命令，而是依赖 `$(USER_TARGET)`，也就是 `xdp_liz_user`。
# 因此运行 `make user` 时，会进一步触发下面的模式规则去编译用户态程序。
user: $(USER_TARGET)

# `$(USER_TARGET): %: %.c` 是模式规则。
# 语法含义是：任意目标 `%` 都可以由同名的 `%.c` 生成。
# 在当前变量展开后，相当于：
# `xdp_liz_user: xdp_liz_user.c`
$(USER_TARGET): %: %.c
	# `$@` 代表当前目标文件名，这里是 `xdp_liz_user`。
	# `$<` 代表第一个依赖文件，这里是 `xdp_liz_user.c`。
	# 这条命令使用 gcc 编译用户态程序，并链接静态 libbpf、libelf、zlib。
	gcc -Wall $(CFLAGS) -Ilibbpf/src -Ilibbpf/src/include/uapi -Llibbpf/src -o $@ \
	 $< -l:libbpf.a -lelf -lz

# `$(BPF_OBJ): %.o: %.c` 也是模式规则。
# 语法含义是：任意 `.o` 目标都可以由同名的 `.c` 文件生成。
# 在当前变量展开后，相当于：
# `xdp_liz_kern.o: xdp_liz_kern.c`
$(BPF_OBJ): %.o: %.c
	# 第一步用 clang 把 C 源文件编译成 LLVM IR 汇编文件 `.ll`。
	# `-S` 表示输出汇编形式；
	# `-target bpf` 表示目标架构是 eBPF；
	# `-emit-llvm` 表示输出 LLVM IR，而不是直接产出机器码。
	# `${@:.o=.ll}` 会把当前目标名中的 `.o` 替换为 `.ll`，
	# 所以这里会生成 `xdp_liz_kern.ll`。
	clang -S \
	    -target bpf \
	    -D __BPF_TRACING__ \
	    -Ilibbpf/src \
	    -Wall \
	    -Wno-unused-value \
	    -Wno-pointer-sign \
	    -Wno-compare-distinct-pointer-types \
	    -Werror \
	    -O2 -emit-llvm -c -o ${@:.o=.ll} $<
	# 第二步用 llc 把 `.ll` 转成最终可加载的 eBPF ELF 对象文件 `.o`。
	llc -march=bpf -filetype=obj -o $@ ${@:.o=.ll}

# `clean` 是清理 target。
# 它没有声明为 `.PHONY`，但从用途上看它是一个伪目标。
# 运行 `make clean` 时，会尝试卸载已挂载的程序并删除构建产物。
clean:
	# 先尝试从 eth0 上解绑 XDP 程序。
	bpftool net detach xdpgeneric dev eth0
	# 删除 pinned 的 bpffs 对象。
	rm -f /sys/fs/bpf/$(TARGET)
	# 删除编译出来的 eBPF 对象文件 `.o`。
	rm $(BPF_OBJ)
	# 删除中间生成的 LLVM IR 文件 `.ll`。
	rm ${BPF_OBJ:.o=.ll}



