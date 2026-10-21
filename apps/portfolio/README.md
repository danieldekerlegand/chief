# Chief Portfolio

The portfolio console is a read-only projection over repository-owned roadmaps, Chief tasklists,
Git activity, private research records, and external agent-run trackers. It is intentionally not a
second project manager: it does not edit a project's roadmap or schedule work.

```sh
cp collectors/portfolio/portfolio.example.json collectors/portfolio/portfolio.json
npm run portfolio:collect
npm run portfolio:serve
```

`portfolio.json` is local configuration and may point at private repositories. Generated
`snapshot.json` contains local paths and private summaries and is ignored by Git.
