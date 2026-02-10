# eval-reports

Eval results tracking and trend dashboards for fulldiveVR projects.

## Structure

```
data/
  {project}/
    history.json          # Append-only array of run summaries
    runs/                 # Full result dumps per run
      {timestamp}.json
index.html                # GitHub Pages dashboard (Chart.js)
```

## Dashboard

Live at: https://fulldivevr.github.io/eval-reports/

## How it works

1. CI workflows in each project run evals
2. After each run, `push-results.ts` builds a summary record and pushes it here
3. `index.html` fetches `history.json` and renders trend charts

## Adding a new project

Create `data/{project-name}/history.json` with `[]` and the dashboard will auto-detect it.
