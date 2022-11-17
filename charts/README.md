# charts

## Local test

Test with [ct](https://github.com/helm/chart-testing) tool:

> run under root dir of the repo.

- `ct lint --charts charts/<the-chart>`
- `ct install --charts charts/<the-chart>`

## TODOs

- [ ] It should be separate to special chart repo.
- [x] Auto release with chart release action.
