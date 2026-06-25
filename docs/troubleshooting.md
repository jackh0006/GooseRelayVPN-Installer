# Troubleshooting

## Check GooseRelayVPN

```bash
systemctl status goose-relay
```

## Check Logs

```bash
journalctl -u goose-relay -n 100
```

## Validate HAProxy

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg
```
