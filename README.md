# basho_bench

一个非常好用的压测工具, 经常用来做 HTTP/TCP 性能测试，并生成测试报表。


## How to install

确保系统中安装了 Erlang/OTP 和 R, 前者是 basho_bench 的运行时，
后者用来生成测试报表。安装这两个依赖之后，安装 basho_bench 如下：

```bash
$ git clone https://github.com/jsvisa/basho_bench.git
$ cd basho_bench
$ make all
```


定义好你自己需要的 driver 和配置文件，以 s3 为例：

```bash
$ ./basho_bench examples/s3.config
```

运行完毕之后，生成报表：

```bash
make results
```

在你的 *tests/current* 目录下, *summary.png* 就是你本次的测试报告。
