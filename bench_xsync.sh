#!/bin/bash
# Compare std.Io.Queue vs iosync.Queue across backends. Parses the internal
# "Duration:" each benchmark prints (excludes process startup).
cd "$(dirname "$0")"
N=${N:-10}

norm() { # "886.038ms" -> milliseconds
  awk '{ v=$0; sub(/[a-zµ]+$/,"",v); u=$0; sub(/^[0-9.]+/,"",u);
         m=1; if(u=="s")m=1000; else if(u=="ms")m=1; else if(u=="us"||u=="µs")m=0.001; else if(u=="ns")m=1e-6;
         printf "%.4f\n", v*m }'
}

bench() {
  local bin=$1 flag=$2
  for i in $(seq 1 "$N"); do
    ./zig-out/bin/"$bin" "$flag" 2>&1 | grep -oE "Duration: [0-9.]+[a-zµ]+" | sed 's/Duration: //' | norm
  done | sort -n | awk -v b="$bin" -v f="$flag" '
    {a[NR]=$1} END{ n=NR; s=0; for(i=1;i<=n;i++)s+=a[i];
      printf "  %-26s %-11s min=%8.2f  med=%8.2f  mean=%8.2f ms\n", b, f, a[1], a[int((n+1)/2)], s/n }'
}

for flag in --threaded --zio-mt --zio; do
  echo "### $flag  (N=$N)"
  for pair in "queue_ping_pong" "queue_fan_in" "worker_pool"; do
    bench "$pair" "$flag"
    bench "${pair}_xsync" "$flag"
  done
  echo
done
