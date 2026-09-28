# Python runtime provider

`runtime-provider.py` is a stdlib-only P8 example. It registers one example-backed `python-reference-service_echo` verb with an isolated host, then serves `GET /health` and `POST /verb/python-reference-service_echo` on its own loopback port.

Run it only against a host and store you own:

```sh
python3 examples/runtime-provider.py \
  --host "$OWNED_HOST_URL" \
  --host-token-file "$OWNED_HOST_TOKEN_FILE" \
  --token-file "$OWNED_PROVIDER_TOKEN_FILE" \
  --port 0
```

Both token files must be private (`0600`). The host token authenticates registration; the host returns a new provider token, which the example saves atomically for invocation and re-registration. No token is printed. Registration refuses a non-loopback host URL. The provider exits if registration fails, and it never chooses a replacement credential itself.
