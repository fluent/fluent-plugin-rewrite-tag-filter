# Picking up a new hostname

`${hostname}` and `__HOSTNAME__` expand to the output of `hostname_command`. The command runs only once, when the plugin is configured, and only when a rule uses one of them. It is not run again while Fluentd is running, so a change of the hostname of the machine is not picked up until the configuration is reloaded.

## How to reload

| How | Sent to | Picks up the new hostname | Notes |
|-----|---------|---------------------------|-------|
| `systemctl reload fluentd` | supervisor | Yes | fluent-package sends `SIGHUP` to the supervisor |
| `SIGHUP` | supervisor | Yes | Restarts the workers. Works with `--daemon` too |
| `SIGUSR2` | supervisor | Yes | Reloads the configuration gracefully. On Fluentd v1.18 or later (except Windows), it starts a zero-downtime restart instead, which took about 13 seconds to switch in the test below, and the PID file gets the PID of the new supervisor |
| `/api/config.reload` of `rpc_endpoint` | supervisor | Yes | Same as `SIGHUP` |
| `/api/config.gracefulReload` of `rpc_endpoint` | supervisor | Yes | |
| `SIGUSR2` | worker | Yes | The worker restarts itself |
| `SIGHUP` | worker | Yes, but not recommended | The worker exits with `SignalException` and the supervisor starts it again, with an error in the log |
| `SIGUSR1` | supervisor or worker | No | Only flushes the buffers and reopens the log file |
| `SIGCONT` | supervisor | No | Only dumps the threads |
| `/api/plugins.flushBuffers` of `rpc_endpoint` | supervisor | No | |
| `/api/processes.killWorkers` of `rpc_endpoint` | supervisor | No | Stops Fluentd. It expects a service manager to start Fluentd again |

## How to see the hostname in use

Set `include_debug_info true` in `in_monitor_agent`, and open `/api/plugins.json?with_ivars=hostname`.

```
<source>
  @type monitor_agent
  port 24220
  include_debug_info true
</source>
```

```
$ curl -s 'http://localhost:24220/api/plugins.json?with_ivars=hostname'
```

The `instance_variables.hostname` of the `rewrite_tag_filter` plugin is the hostname in use. It is empty when no rule uses the hostname.

## How it was tested

Tested with Fluentd v1.16.11 and v1.20.1 on Linux (Docker), in the foreground and with `--daemon`.

1. Start Fluentd with the configuration below, where `hostname_command` reads `/tmp/h`, which has `old`.
2. Write `new` to `/tmp/h`.
3. Send the signal, or call the RPC endpoint.
4. Check whether the events emitted within 30 seconds have the tag `new.out`.

```
<system>
  rpc_endpoint 127.0.0.1:24444
</system>
<source>
  @type sample
  sample {"message":"x"}
  tag app
</source>
<match app>
  @type rewrite_tag_filter
  hostname_command cat /tmp/h
  <rule>
    key message
    pattern /x/
    tag ${hostname}.out
  </rule>
</match>
<match **>
  @type stdout
</match>
```
