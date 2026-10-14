# CI fixtures

Files created by `.github/workflows/ci.yml` and `release.yml` to run `kamailio -c` against the built image live
here at run time (`local.cfg` and a variant with every switch on, a throwaway TLS pair and `tls.cfg`). The only
committed input is `fixture.cfg` - a fake `local.cfg` with the switches commented out; the workflows copy it and
turn the switches on with sed. It is not a template: the operator's template is `deploy/local.cfg.example` in the
umbrella repository.
