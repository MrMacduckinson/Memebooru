# Deploying the public gallery

An origin stores the **public export** and serves it with Caddy. An optional intermediate reverse proxy connects a CDN to that origin. The intermediate server does not need a copy of the collection; a local cache is optional.

## Data isolation

1. Create a separate collection, import the prepared manifest into staging and explicitly commit its entries.
2. Run `gallery publish` into a **new** directory.
3. Mount only that directory, read-only, in the web container.
4. Keep the native collection outside the web root.

Only allowlisted originals, thumbnails and public metadata are exported. There is no public administration API. Favorites stay in each visitor's browser, without accounts or server uploads.

## Start and HTTPS

```sh
PUBLIC_GALLERY=/srv/memebooru/public-v1 \
  docker compose -f docker-compose.web.yml up -d --build
```

An external HTTPS proxy should forward to `127.0.0.1:8080`. Example for a **separate** Caddy on the host; substitute your domain:

```caddy
gallery.example.org {
    reverse_proxy 127.0.0.1:8080
}
```

If the proxy is on another machine, secure the connection between hosts with verified certificates or a private encrypted tunnel, and restrict firewall sources. Do not publish infrastructure addresses, keys or private configurations in the application repository.

## CDN

- `/media/*` and `/thumbs/*`: SHA-256 filenames; cache for one year (`immutable`).
- `/catalogue.json`: short 60-second TTL.
- HTML/JS/CSS: revalidate after updates (`no-cache`).
- Preserve the origin's `Cache-Control` headers; avoid a blanket cache rule.
- Configure origin HTTPS and the correct Host/SNI for your CDN.

Unrelated protocols and VPN traffic are outside this repository's configuration.

## Updates and rollback

Publish into a separate `public-v2` directory, test it locally, then recreate the container with the new `PUBLIC_GALLERY`. A single Compose service may briefly interrupt active downloads during this switch; this is not a rolling deployment. Roll back by restoring `public-v1`. Remove old exports only after verification and completion of old downloads.

Purge CDN HTML/JS/CSS caches when updating; hashed images do not require a purge. Back up each published export and back up the native collection separately.

## Resources and checks

The serving host needs neither Swift nor a tagging model. The container is limited to 256 MiB RAM and one CPU; actual usage depends on connections and throughput. Origin disk must hold originals, previews and room for updates. Generate tags and thumbnails before deployment.

```sh
curl -I http://127.0.0.1:8080/
curl -I http://127.0.0.1:8080/catalogue.json
curl -I http://127.0.0.1:8080/collection.db # must return 404
```

Docker logs are bounded to 3 × 10 MB; writable temporary directories use tmpfs. Visitor request logging is disabled by default.
