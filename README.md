# exp-geoip2

The MaxMind GeoLite2 Country database, republished as GitHub releases so that
[DC++ Experimental](https://github.com/iceman50/DCPlusPlus-Experimental) can keep
its country lookups up to date without each user needing a MaxMind account.

This repository holds no data itself. A scheduled GitHub Actions workflow checks
MaxMind once a day and, when a new build is out, publishes it as a release named
after its build date (for example `geolite2-20261124`). Only the three newest
releases are kept.

## Download

The newest database is always at:

```
https://github.com/iceman50/exp-geoip2/releases/latest/download/GeoLite2-Country.mmdb
```

Each release also has a `SHA256SUMS` file for checking the download.

DC++ Experimental uses this link by default (View > Experimental > Other >
Country database), and checks it once a day while it runs.

## How it works

- [`geolite2-to-github.sh`](geolite2-to-github.sh) asks MaxMind for the current
  build date with a HEAD request, which doesn't count towards MaxMind's daily
  download limit. If a release for that build already exists, it stops there.
- Otherwise it downloads the database, checks it against MaxMind's SHA-256,
  extracts the `.mmdb` file and creates the release.
- [`.github/workflows/publish.yml`](.github/workflows/publish.yml) runs the script
  daily and can also be started by hand from the Actions tab.

## Setup

The workflow needs two repository secrets (Settings > Secrets and variables >
Actions), from <https://www.maxmind.com/en/accounts/current/license-key>:

- `MAXMIND_ACCOUNT_ID`
- `MAXMIND_LICENSE_KEY`

Or with the GitHub CLI:

```sh
gh secret set MAXMIND_ACCOUNT_ID -R iceman50/exp-geoip2
gh secret set MAXMIND_LICENSE_KEY -R iceman50/exp-geoip2
gh workflow run publish.yml -R iceman50/exp-geoip2
```

GitHub turns off scheduled workflows in a public repository after 60 days without
activity. It sends an email first, and the workflow can be turned back on from
the Actions tab.

The script can also run from cron on any Linux machine with `curl` and the
GitHub CLI: copy [`geolite2-github.conf.example`](geolite2-github.conf.example)
to `~/.config/geolite2-github.conf`, fill it in, and run
`geolite2-to-github.sh --help` for the options.

## Attribution

This product includes GeoLite2 data created by MaxMind, available from
<https://www.maxmind.com>. The data is provided under the
[GeoLite2 End User License Agreement](https://www.maxmind.com/en/geolite2/eula).
