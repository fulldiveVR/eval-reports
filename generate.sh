#!/usr/bin/env bash
# Generate index.html from all project data in data/*/history.json
# Usage: ./generate.sh

set -euo pipefail
cd "$(dirname "$0")"

# Auto-discover projects
PROJECTS=()
for dir in data/*/; do
  if [ -f "${dir}history.json" ]; then
    PROJECTS+=("$(basename "$dir")")
  fi
done

if [ ${#PROJECTS[@]} -eq 0 ]; then
  echo "No projects found in data/"
  exit 0
fi

echo "Found projects: ${PROJECTS[*]}"

# Build <option> tags
OPTIONS=""
for p in "${PROJECTS[@]}"; do
  OPTIONS="${OPTIONS}    <option value=\"${p}\">${p}</option>\n"
done

cat > index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Eval Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, monospace; background: #0d1117; color: #c9d1d9; padding: 24px; }
  h1 { font-size: 24px; margin-bottom: 8px; color: #f0f6fc; }
  .subtitle { color: #8b949e; margin-bottom: 24px; font-size: 14px; }
  .controls { display: flex; gap: 12px; align-items: center; margin-bottom: 24px; flex-wrap: wrap; }
  select { background: #161b22; color: #c9d1d9; border: 1px solid #30363d; padding: 6px 12px; border-radius: 6px; font-size: 14px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px; }
  @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
  .card h2 { font-size: 14px; color: #8b949e; margin-bottom: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
  .full-width { grid-column: 1 / -1; }
  .banner { padding: 12px 16px; border-radius: 8px; margin-bottom: 16px; font-size: 14px; font-weight: 600; }
  .banner.red { background: #3d1418; border: 1px solid #f8514966; color: #ff7b72; }
  .banner.green { background: #12261e; border: 1px solid #3fb95066; color: #3fb950; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 8px 12px; border-bottom: 1px solid #30363d; color: #8b949e; font-weight: 600; }
  td { padding: 6px 12px; border-bottom: 1px solid #21262d; }
  .pass { color: #3fb950; }
  .fail { color: #f85149; }
  .score { color: #d2a8ff; }
  .stat-row { display: flex; gap: 24px; margin-bottom: 16px; flex-wrap: wrap; }
  .stat { text-align: center; }
  .stat .value { font-size: 32px; font-weight: 700; color: #f0f6fc; }
  .stat .label { font-size: 12px; color: #8b949e; margin-top: 4px; }
  .loading { text-align: center; padding: 48px; color: #8b949e; }
  canvas { max-height: 300px; }
</style>
</head>
<body>

<h1>Eval Dashboard</h1>
<p class="subtitle">Automated evaluation tracking and regression detection</p>

<div class="controls">
  <label>Project:</label>
  <select id="projectSelect">
HTMLEOF

# Inject project options
for p in "${PROJECTS[@]}"; do
  echo "    <option value=\"${p}\">${p}</option>" >> index.html
done

cat >> index.html << 'HTMLEOF'
  </select>
  <label>Last:</label>
  <select id="rangeSelect">
    <option value="30">30 runs</option>
    <option value="60">60 runs</option>
    <option value="0">All</option>
  </select>
</div>

<div id="alerts"></div>

<div class="stat-row" id="stats">
  <div class="loading">Loading data...</div>
</div>

<div class="grid">
  <div class="card">
    <h2>Pass Rate Over Time</h2>
    <canvas id="passRateChart"></canvas>
  </div>
  <div class="card">
    <h2>LLM Scores Over Time</h2>
    <canvas id="scoresChart"></canvas>
  </div>
  <div class="card">
    <h2>Execution Time Trend</h2>
    <canvas id="durationChart"></canvas>
  </div>
  <div class="card">
    <h2>Category Breakdown (Latest)</h2>
    <canvas id="categoryChart"></canvas>
  </div>
  <div class="card full-width">
    <h2>Latest Run Details</h2>
    <div id="latestTable"><div class="loading">Loading...</div></div>
  </div>
</div>

<script>
const CHART_COLORS = [
  '#58a6ff', '#3fb950', '#d2a8ff', '#f0883e', '#f85149',
  '#a5d6ff', '#7ee787', '#d8b4fe', '#ffa657', '#ff7b72'
];

const chartDefaults = {
  responsive: true,
  maintainAspectRatio: true,
  plugins: { legend: { labels: { color: '#8b949e', font: { size: 11 } } } },
  scales: {
    x: { ticks: { color: '#484f58', font: { size: 10 } }, grid: { color: '#21262d' } },
    y: { ticks: { color: '#484f58', font: { size: 10 } }, grid: { color: '#21262d' } }
  }
};

let charts = {};

function destroyCharts() {
  Object.values(charts).forEach(c => c.destroy());
  charts = {};
}

function formatDate(ts) {
  const d = new Date(ts);
  return `${(d.getMonth()+1).toString().padStart(2,'0')}/${d.getDate().toString().padStart(2,'0')} ${d.getHours().toString().padStart(2,'0')}:${d.getMinutes().toString().padStart(2,'0')}`;
}

function formatDuration(ms) {
  if (ms == null) return '-';
  if (ms < 1000) return ms + 'ms';
  if (ms < 60000) return (ms/1000).toFixed(1) + 's';
  return (ms/60000).toFixed(1) + 'm';
}

function scenarioDuration(s) {
  return s.duration || s.durationMs || null;
}

function detectRegressions(runs) {
  if (runs.length < 6) return [];
  const latest = runs[runs.length - 1];
  const regressions = [];

  for (const scenario of (latest.scenarios || [])) {
    if (scenario.score == null) continue;
    const prev = [];
    for (let i = Math.max(0, runs.length - 6); i < runs.length - 1; i++) {
      const s = (runs[i].scenarios || []).find(sc => sc.id === scenario.id);
      if (s && s.score != null) prev.push(s.score);
    }
    if (prev.length < 3) continue;
    const avg = prev.reduce((a,b) => a+b, 0) / prev.length;
    const drop = avg - scenario.score;
    if (drop > 10) {
      regressions.push({ id: scenario.id, score: scenario.score, avg: avg.toFixed(1), drop: drop.toFixed(1) });
    }
  }

  const prevRates = [];
  for (let i = Math.max(0, runs.length - 6); i < runs.length - 1; i++) {
    if (runs[i].summary) prevRates.push(runs[i].summary.passRate);
  }
  if (prevRates.length >= 3) {
    const avgRate = prevRates.reduce((a,b) => a+b, 0) / prevRates.length;
    const rateDrop = avgRate - (latest.summary?.passRate || 0);
    if (rateDrop > 15) {
      regressions.push({ id: '_overall_pass_rate', score: latest.summary.passRate, avg: avgRate.toFixed(1), drop: rateDrop.toFixed(1) });
    }
  }

  return regressions;
}

function renderAlerts(regressions) {
  const el = document.getElementById('alerts');
  if (regressions.length === 0) {
    el.innerHTML = '<div class="banner green">No regressions detected</div>';
    return;
  }
  const items = regressions.map(r =>
    r.id === '_overall_pass_rate'
      ? `Overall pass rate dropped ${r.drop} points (${r.avg}% avg &rarr; ${r.score}%)`
      : `${r.id}: score dropped ${r.drop} points (${r.avg} avg &rarr; ${r.score})`
  ).join('<br>');
  el.innerHTML = `<div class="banner red">Regression detected:<br>${items}</div>`;
}

function renderStats(runs) {
  const el = document.getElementById('stats');
  if (runs.length === 0) {
    el.innerHTML = '<div class="loading">No data yet</div>';
    return;
  }
  const latest = runs[runs.length - 1];
  const s = latest.summary || {};
  el.innerHTML = `
    <div class="stat"><div class="value">${runs.length}</div><div class="label">Total Runs</div></div>
    <div class="stat"><div class="value">${s.total || '-'}</div><div class="label">Scenarios</div></div>
    <div class="stat"><div class="value ${(s.passRate||0) >= 80 ? 'pass' : 'fail'}">${s.passRate != null ? s.passRate.toFixed(1)+'%' : '-'}</div><div class="label">Pass Rate (Latest)</div></div>
    <div class="stat"><div class="value">${latest.duration ? formatDuration(latest.duration) : '-'}</div><div class="label">Duration (Latest)</div></div>
    <div class="stat"><div class="value">${latest.model || '-'}</div><div class="label">Model</div></div>
  `;
}

function renderPassRateChart(runs) {
  const labels = runs.map(r => formatDate(r.timestamp));
  const datasets = [{ label: 'Total', data: runs.map(r => r.summary?.passRate ?? null), borderColor: CHART_COLORS[0], tension: 0.3, fill: false }];

  const allCats = new Set();
  runs.forEach(r => { if (r.categories) Object.keys(r.categories).forEach(c => allCats.add(c)); });
  let ci = 1;
  for (const cat of [...allCats].sort()) {
    datasets.push({
      label: cat,
      data: runs.map(r => {
        const c = r.categories?.[cat];
        return c ? (c.total > 0 ? (c.passed / c.total * 100) : null) : null;
      }),
      borderColor: CHART_COLORS[ci % CHART_COLORS.length],
      borderDash: [5, 3],
      tension: 0.3,
      fill: false
    });
    ci++;
  }

  charts.passRate = new Chart(document.getElementById('passRateChart'), {
    type: 'line', data: { labels, datasets },
    options: { ...chartDefaults, scales: { ...chartDefaults.scales, y: { ...chartDefaults.scales.y, min: 0, max: 100, title: { display: true, text: '%', color: '#484f58' } } } }
  });
}

function renderScoresChart(runs) {
  const labels = runs.map(r => formatDate(r.timestamp));
  const scoredScenarios = new Set();
  runs.forEach(r => (r.scenarios || []).forEach(s => { if (s.score != null) scoredScenarios.add(s.id); }));

  const datasets = [];
  let ci = 0;
  for (const sid of [...scoredScenarios].sort()) {
    datasets.push({
      label: sid.replace(/^llm-\d+-/, ''),
      data: runs.map(r => {
        const s = (r.scenarios || []).find(sc => sc.id === sid);
        return s?.score ?? null;
      }),
      borderColor: CHART_COLORS[ci % CHART_COLORS.length],
      tension: 0.3,
      fill: false,
      spanGaps: true
    });
    ci++;
  }

  if (datasets.length === 0) {
    document.getElementById('scoresChart').parentElement.querySelector('h2').textContent = 'LLM SCORES OVER TIME (no scored scenarios)';
    return;
  }

  charts.scores = new Chart(document.getElementById('scoresChart'), {
    type: 'line', data: { labels, datasets },
    options: { ...chartDefaults, scales: { ...chartDefaults.scales, y: { ...chartDefaults.scales.y, min: 0, max: 100, title: { display: true, text: 'Score', color: '#484f58' } } } }
  });
}

function renderDurationChart(runs) {
  const labels = runs.map(r => formatDate(r.timestamp));
  charts.duration = new Chart(document.getElementById('durationChart'), {
    type: 'line',
    data: {
      labels,
      datasets: [{ label: 'Total Duration', data: runs.map(r => r.duration ? r.duration / 1000 : null), borderColor: '#f0883e', backgroundColor: '#f0883e22', tension: 0.3, fill: true }]
    },
    options: { ...chartDefaults, scales: { ...chartDefaults.scales, y: { ...chartDefaults.scales.y, title: { display: true, text: 'seconds', color: '#484f58' } } } }
  });
}

function renderCategoryChart(runs) {
  if (runs.length === 0) return;
  const latest = runs[runs.length - 1];
  const cats = latest.categories || {};
  const labels = Object.keys(cats).sort();
  charts.category = new Chart(document.getElementById('categoryChart'), {
    type: 'bar',
    data: {
      labels,
      datasets: [
        { label: 'Passed', data: labels.map(l => cats[l].passed), backgroundColor: '#3fb950' },
        { label: 'Failed', data: labels.map(l => cats[l].failed), backgroundColor: '#f85149' }
      ]
    },
    options: { ...chartDefaults, scales: { ...chartDefaults.scales, x: { ...chartDefaults.scales.x, stacked: true }, y: { ...chartDefaults.scales.y, stacked: true, beginAtZero: true } } }
  });
}

function renderLatestTable(runs) {
  const el = document.getElementById('latestTable');
  if (runs.length === 0) { el.innerHTML = '<p>No data</p>'; return; }
  const latest = runs[runs.length - 1];
  const scenarios = latest.scenarios || [];
  if (scenarios.length === 0) { el.innerHTML = '<p>No scenario details in latest run</p>'; return; }

  let html = '<table><thead><tr><th>Scenario</th><th>Category</th><th>Status</th><th>Duration</th><th>Score</th><th>Error</th></tr></thead><tbody>';
  for (const s of scenarios.sort((a,b) => a.id.localeCompare(b.id))) {
    const status = s.passed ? '<span class="pass">PASS</span>' : '<span class="fail">FAIL</span>';
    const dur = formatDuration(scenarioDuration(s));
    const score = s.score != null ? `<span class="score">${s.score}</span>` : '-';
    const err = s.error ? `<span class="fail">${s.error.substring(0, 80)}</span>` : '-';
    html += `<tr><td>${s.id}</td><td>${s.category||'-'}</td><td>${status}</td><td>${dur}</td><td>${score}</td><td>${err}</td></tr>`;
  }
  html += '</tbody></table>';
  el.innerHTML = html;
}

async function loadAndRender() {
  const project = document.getElementById('projectSelect').value;
  const range = parseInt(document.getElementById('rangeSelect').value);

  try {
    const resp = await fetch(`data/${project}/history.json`);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    let runs = await resp.json();
    if (range > 0) runs = runs.slice(-range);

    destroyCharts();
    const regressions = detectRegressions(runs);
    renderAlerts(regressions);
    renderStats(runs);
    renderPassRateChart(runs);
    renderScoresChart(runs);
    renderDurationChart(runs);
    renderCategoryChart(runs);
    renderLatestTable(runs);
  } catch (e) {
    document.getElementById('stats').innerHTML = `<div class="loading">Error loading data: ${e.message}</div>`;
    document.getElementById('alerts').innerHTML = '';
  }
}

document.getElementById('projectSelect').addEventListener('change', loadAndRender);
document.getElementById('rangeSelect').addEventListener('change', loadAndRender);
loadAndRender();
</script>
</body>
</html>
HTMLEOF

echo "Generated index.html with projects: ${PROJECTS[*]}"
