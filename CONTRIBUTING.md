# Contributing

Contributions are welcome through pull requests.

Please keep the core sync logic provider-read-only and avoid committing real tenant names, private site URLs, document names, credentials or copied confidential content in examples/tests.

Before opening a pull request:

```bash
bash -n setup-fedora.sh
python3 scripts/validate-config.py config/projects.example.json
python3 -m unittest discover -s tests -v
```

PowerShell files must parse cleanly under the current supported PowerShell release.
