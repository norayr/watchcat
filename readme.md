# watchcat
## ոչ շուն ոչ կատու

watchcat combines good things about watch and cat.

it also might be useful on bsd systems that are lucking watch afaik.

```
$ watchcat --help
watchcat 1.0
Usage: watchcat [OPTIONS] -- COMMAND [ARGS...]
       watchcat [OPTIONS] -f FILENAME
Options:
  -n, --interval INTERVAL  Update interval (e.g., 2s, 500ms)
  -f, --file FILENAME      Monitor file changes
      --clear              Clear screen between updates
      --no-clear           Do not clear screen between updates
                           (In command mode, clear is default)
                           (In file mode, no-clear is default)
  -d, --diff               Highlight differences (useful for commands)
  -t, --timestamp          Show timestamp when changes occur
  --help                   Show this help
```

also you can watch [this video](https://toobnix.org/w/rUCuvw4UHvtkorPnawtHKJ).

