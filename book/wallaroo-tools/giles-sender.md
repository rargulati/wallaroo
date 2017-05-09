# Giles Sender

## Overview

Giles components act as external testers for Wallaroo. Giles Sender is used to mimic the behavior of an incoming data source. Giles Sender sends data to Wallaroo in one of four ways:

- With no other commandline options given, it will send string representations of integers, starting with `1` and increasing by `1` with each new message. For example, `./giles/sender -b 127.0.0.1:8081 -m 100` will send messages containing string representations of the numbers `1` through `100`.
- With a file name given as the `--file/-f` argument it will send each line of the given file as a message. For example, `./giles/sender -b 127.0.0.1:8081 -m 100 -f war-and-peace.txt` will send messages containing each of the first 100 lines of the file `war-and-peace.txt`.
- With a file name given as the `--file/-f` argument and binary format specified with `--binary/-y` and every message is 24 bytes, specified with `--msg-size/-g`, it will send every 24 bytes of the given file as a message. For example, `./giles/sender -b 127.0.0.1:8081 -m 100 -f binary-data-file.txt -y -g 24` will send every 24 bytes until it has sent 100 messages
- With a file name given as the `--file/-f` argument and binary format specified with `--binary/-y` and variable message lengths specified with `--variable-size/-z`, it will read 4 bytes to get the message size, send that message and repeat. For example, `./giles/sender  127.0.0.1:8081 -m 100 -f binary-data-file.txt -y -z` will initially read a 4 byte header, send that message and repeat until it has sent 100 messages.

### Building `giles/sender`

If you do not already have the `wallaroo` repo, create a local copy:

```bash
git clone https://github.com/sendence/wallaroo
```

Compile the `giles-sender` binary:

```bash
cd wallaroo/giles/sender
stable env ponyc
```

## Command Line Arguments

`giles/sender` takes several command line arguments, below is a list with accompanying notes:

* `--buffy/-b` address and port combination that Wallaroo is listening on for incoming source data. Must be provided in the `127.0.0.1:8082` format.
* `--messages/-m` number of messages to send before terminating the sender.
* `--file/-f` a file with newline-separated entries from which to read entries to send. If multiple files are provided, the first file is read to the end before the next file is open and read, and so on.
* `--batch-size/-s` specifies the number of messages sent at every interval.
* `--interval/-i` interval at which to send a batch of messages to Wallaroo. Defaults to `5_000_000`. The value is in nanoseconds.
* `--repeat/-r` tells the sender to repeat reading the file/s as long as necessary to send the number of messages specified by `-m`.
* `--binary/-y` a flag to pass if the data source file is in binary format.
* `--u64/-u` send binary-encoded U64 values, starting from offset and incrementing by 1. The first value sent is offset+1.
* `--start-from/-v` Set the offset for use with `--u64/-u` or when `--file/-f` is not used.
* `--variable-size/-z` a flag to pass if using binary format and the binary messages have varying lengths. Cannot be used with `--msg-size/-g`.
* `--msg-size/-g` the size of the binary message in bytes. Cannot be used with `--variable-size/-z`.
* `--no-write/-w` flag to stop the `sender` from writing the messages sent to file.
* `--phone-home/-p` Dagon address. Must be provided in the `127.0.0.1:8082` format. Only used when run by Dagon.
* `--name/-n` Name to register itself with to Dagon. Only used when run by Dagon.

## Examples

### Send words from a file

Each line contains a word

```bash
# words.txt
hello
world
lorem
ipsum
sit
amet
```

Use

```bash
sender --buffy 127.0.0.1:7000 --file words.txt --messages 100 --repeat
```

### Send binary data from a file

#### Fixed Length Data

In this case, the data in the file is already [framed](/book/appendix/writing-your-own-feed.md#source-message-framing-protocol), and the `--msg-length` parameter is the number of bytes for the message _and_ the length header.

With a 4-byte header and 6-bytes of text, coming to a total of 10-bytes:

```bash
# my_binary_data_file
\x00\x00\x00\x04123456
\x00\x00\x00\x04abcdef
```

Use

```bash
sender --buffy 127.0.0.1:7000 --file=my_binary_data_file --messages=10 \
  --repeat --batch-size=1 --interval=10_000_000 --binary --msg-size 10 \
  --no-write
```

#### Variable Length Data

In this case, the data in the file is frame encoded, but the message length is not constant.

```bash
# my_variable_binary_data_file
\x00\x00\x00\x041234
\x00\x00\x00\x011
\x00\x00\x00\x0bhello world
```

Use

```bash
sender --buffy 127.0.0.1:7000 --file=my_variable_binary_data_file --messages=10 \
  --repeat --batch-size=1 --interval=10_000_000 --binary --variable-size \
  --no-write
```

### Multiple Input Files

When using multiple input files, `sender` effectively concatenates the files by reading the first file to the end, then reading the next file, and so on.
You can use this to concatenate multiple files, or to repeat the same file (although in this case, the `--repeat` option is better suited).

With the files

```bash
# file1
12
34
56

# file2
78
90
ab
bc
```

To concatenate the files, in order, use

```bash
sender --buffy 127.0.0.1:7000 --file=file1,file2 --messages=100 --batch-size=1 \
  --interval=10_000_000 --no-write
```

To send the contents of the first file twice, then the contents of the second file once, use

```bash
sender --buffy 127.0.0.1:7000 --file=file1,file1,file2 --messages=100 \
  --batch-size=1 --interval=10_000_000 --no-write
```

Multiple input files are also supported for binary input, but they must all be either fixed length or variable length.

### Send a sequence of numbers, encoded as strings

To send the sequence `'1', '2', '3', ..., '100'`


Use

```bash
sender --buffy 127.0.0.1:7000 --messages 100
```

### Send a sequence of numbers, encoded as big-endian U64

To send the sequence `1,2,3,...,100`

Use

```bash
sender --buffy 127.0.0.1:7000 --messages 100 --u64
```

To send the sequence `101,102,...,200`

Use

```bash
sender --buffy 127.0.0.1:7000 --messages 100 --u64 --start-from 100
```

## Preparing Data Files for Giles Sender

`sender` has three modes for file input:

1. newline delimited text
2. fixed-length binary
3. variable-lengh binary

To create a data file for the first case, store your records separated by newlines in a file.
To create data for the binary cases, follow the [framing protocol](/book/appendix/writing-your-own-feed.md#source-message-framing-protocol).


## Pony Runtime Options

The following pony runtime parameters may also be useful in some situations

* `--ponythreads` limits the number of threads the pony runtime will use.
* `--ponynoblock`
* `--ponypinasio`