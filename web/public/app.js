'use strict';

// Live data stays in memory. Never write host data, logs, or credentials to storage.
(() => {
  const $ = (id) => document.getElementById(id);
  const number = (value) => value !== null && value !== undefined && value !== '' && Number.isFinite(Number(value));
  const fixed = (value, digits = 1) => number(value) ? Number(value).toFixed(digits) : '—';
  const clamp = (value) => Math.max(0, Math.min(100, Number(value) || 0));
  const bytes = (value) => {
    if (!number(value)) return '—';
    const amount = Math.max(0, Number(value));
    if (amount < 1024) return `${Math.round(amount)} B`;
    const power = Math.min(4, Math.floor(Math.log(amount) / Math.log(1024)));
    return `${(amount / 1024 ** power).toFixed(power > 1 ? 1 : 0)} ${['B', 'KiB', 'MiB', 'GiB', 'TiB'][power]}`;
  };
  const date = (value) => {
    if (!value) return null;
    const result = new Date(value);
    return Number.isNaN(result.getTime()) ? null : result;
  };
  const time = (value) => {
    const parsed = date(value);
    return parsed ? parsed.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', second: '2-digit' }) : 'Not recorded';
  };
  const relative = (value) => {
    const parsed = date(value);
    if (!parsed) return 'Not recorded';
    const seconds = Math.max(0, (Date.now() - parsed.getTime()) / 1000);
    if (seconds < 60) return 'Just now';
    if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)} hr ago`;
    return parsed.toLocaleDateString([], { month: 'short', day: 'numeric' });
  };
  const duration = (value) => {
    if (!number(value)) return '—';
    const days = Math.floor(value / 86400);
    const hours = Math.floor(value / 3600) % 24;
    const minutes = Math.floor(value / 60) % 60;
    return days ? `${days}d ${hours}h` : hours ? `${hours}h ${minutes}m` : `${minutes} min`;
  };
  function element(tag, className, text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = String(text);
    return result;
  }
  function set(id, value) { $(id).textContent = value ?? '—'; }
  const tone = (state) => ['failed', 'unhealthy', 'error', 'exited', 'dead', 'stopped'].includes(state) ? 'error' : ['stale', 'warning', 'restarting', 'starting'].includes(state) ? 'warning' : ['running', 'healthy', 'up', 'external'].includes(state) ? '' : 'neutral';
  function badge(text, state) { return element('span', `badge ${tone(state)}`, text); }
  function dot(state) { const node = element('span', `status-dot ${tone(state)}`); node.setAttribute('aria-hidden', 'true'); return node; }
  function safeUrl(value) {
    try { const url = new URL(value); return ['http:', 'https:'].includes(url.protocol) ? url.href : null; } catch { return null; }
  }
  function fact(label, value, wide = false) {
    const wrapper = element('div', wide ? 'detail-wide' : '');
    wrapper.append(element('dt', '', label), element('dd', '', value));
    return wrapper;
  }

  let snapshot = null;
  let filter = 'all';
  let paused = false;
  let authenticated = true;
  let active = true;
  let epoch = 0;
  let statusTimer;
  let logTimer;
  let lastLogText = '';
  let lastLogSource = '';
  let statusRequest = null;
  let logRequest = null;
  let installPrompt = null;

  class SessionError extends Error {}
  async function request(path, controller) {
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: controller.signal, headers: { Accept: 'application/json' } });
      if (response.status === 401 || response.status === 403 || response.redirected) throw new SessionError();
      if (!response.ok) throw new Error(`Host returned ${response.status}`);
      if (!(response.headers.get('content-type') || '').includes('application/json')) throw new SessionError();
      return await response.json();
    } finally { clearTimeout(timer); }
  }

  function notice(message, session = false) {
    $('connection-notice').hidden = false;
    set('connection-message', message);
    $('reconnect').hidden = !session;
  }
  function overall(label, state) {
    if ($('overall-status').textContent === label) return;
    $('overall-status').replaceChildren(dot(state), document.createTextNode(label));
  }
  function statusLoading(loading) {
    const firstReading = loading && !snapshot;
    document.body.classList.toggle('is-loading', firstReading);
    document.querySelectorAll('[data-loading-region]').forEach((node) => node.setAttribute('aria-busy', String(firstReading)));
    $('refresh').disabled = loading || !authenticated || !active || !navigator.onLine;
    set('refresh', loading ? (snapshot ? 'Refreshing…' : 'Loading…') : 'Refresh ↻');
    if (firstReading) {
      overall('Reading the host…', 'loading');
      set('last-updated', 'The first reading takes a few seconds');
      set('deploy-badge', 'Loading'); $('deploy-badge').className = 'badge neutral';
      set('deploy-title', 'Reading the heartbeat');
    }
  }
  function logLoading(loading, firstReading = false) {
    $('log-output').setAttribute('aria-busy', String(loading && firstReading));
    $('log-status').classList.toggle('is-fetching', loading);
    if (loading && firstReading) set('log-status', 'Reading output…');
  }
  function clearSensitive() {
    epoch += 1;
    statusRequest?.abort();
    logRequest?.abort();
    snapshot = null;
    statusLoading(false); logLoading(false);
    overall('Waiting for a live connection', 'neutral');
    lastLogText = '';
    lastLogSource = '';
    ['disk-used','disk-free','disk-available','memory-used','memory-total','load-current','load-five','load-fifteen','cpu-count','running-count','configured-running','deploy-checked','deploy-success','deploy-branch','deploy-commit','host-uptime','inventory-count'].forEach((id) => set(id, '—'));
    ['disk-occupied','disk-reclaimable','memory-meter'].forEach((id) => { $(id).style.width = '0%'; });
    $('disk-meter').setAttribute('aria-label', 'Disk utilization unavailable');
    $('deploy-checked').removeAttribute('title'); $('deploy-success').removeAttribute('title');
    set('host-name', 'Mac mini'); set('host-os', 'Production host'); set('docker-storage', 'Docker storage is measured by allocated disk space.');
    set('disk-state', 'Macintosh HD'); $('disk-state').className = 'small-tag'; set('memory-state', 'Host');
    set('memory-note', 'Current host memory usage');
    set('unconfigured-summary', 'Waiting for a fresh inventory'); $('unconfigured-summary').className = 'metric-note';
    set('deploy-title', 'Live connection required');
    set('deploy-message', 'Sign in and reconnect to read the production host.');
    set('deploy-badge', 'Unavailable'); $('deploy-badge').className = 'badge neutral';
    set('last-updated', 'Live readings unavailable');
    set('application-count', 'From the production configuration');
    set('filter-count', '0');
    $('warnings').replaceChildren(); $('container-tally').replaceChildren();
    $('application-list').replaceChildren(element('p', 'empty-state', 'Connect to see configured applications.'));
    $('container-list').replaceChildren(element('p', 'empty-state', 'Connect to see the Docker inventory.'));
    $('log-source').replaceChildren(element('option', '', 'Live connection required'));
    $('log-source').disabled = true;
    set('log-output', 'Live logs are not stored offline.');
    set('log-status', 'Disconnected');
    set('log-detail', 'Up to 100 recent lines · refreshes every 5 seconds');
    $('copy-logs').disabled = true; $('pause-logs').disabled = true;
    $('filter-all').disabled = true; $('filter-unconfigured').disabled = true;
  }
  function sessionExpired() {
    authenticated = false;
    clearTimeout(statusTimer); clearTimeout(logTimer);
    clearSensitive();
    overall('Sign in to reconnect', 'warning');
    notice('Your Cloudflare session has ended. Sign in again to see live readings.', true);
  }
  function renderStatus(data) {
    snapshot = data;
    $('filter-all').disabled = false; $('filter-unconfigured').disabled = false;
    const host = data.host || {};
    const disk = host.disk || {};
    const memory = host.memory || {};
    const deploy = data.deployment || {};
    const containers = Array.isArray(data.containers) ? data.containers : [];
    const running = containers.filter((item) => item.state === 'running');
    const unmanaged = running.filter((item) => !item.configured && !item.transient);
    const applications = Array.isArray(data.applications) ? data.applications : [];
    const errors = Array.isArray(data.errors) ? data.errors : [];
    const warnings = Array.isArray(data.warnings) ? data.warnings : [];
    const inventoryAvailable = !errors.some((error) => error.source === 'Docker inventory');
    $('filter-all').disabled = !inventoryAvailable; $('filter-unconfigured').disabled = !inventoryAvailable;
    const critical = deploy.status === 'failed' || disk.level === 'critical';
    const attention = critical || unmanaged.length || errors.length || warnings.length || ['stale','unknown'].includes(deploy.status) || running.some((item) => item.health === 'unhealthy');
    overall(critical ? 'The host needs attention' : attention ? 'A few things to keep an eye on' : deploy.status === 'running' ? 'Heartbeat in progress' : 'All systems steady', critical ? 'error' : attention ? 'warning' : 'healthy');
    set('last-updated', `Updated ${time(data.generated_at)}`);
    set('disk-used', fixed(disk.used_percent, 0));
    set('disk-free', bytes(disk.free_bytes));
    set('disk-available', bytes(disk.available_bytes));
    $('disk-state').className = `small-tag ${disk.level === 'critical' ? 'tone-error' : ''}`;
    set('disk-state', disk.level === 'critical' ? 'Low free space' : 'Macintosh HD');
    const raw = clamp(disk.used_percent);
    const effective = number(disk.effective_used_percent) ? clamp(disk.effective_used_percent) : raw;
    $('disk-occupied').style.width = `${Math.min(raw, effective)}%`;
    $('disk-reclaimable').style.width = `${Math.max(0, raw - effective)}%`;
    $('disk-meter').setAttribute('aria-label', number(disk.used_percent) ? `${fixed(raw, 0)} percent occupied; ${fixed(effective, 0)} percent used after reclaimable space; ${bytes(disk.free_bytes)} immediately free` : 'Disk utilization unavailable');
    set('memory-used', number(memory.used_bytes) ? fixed(memory.used_bytes / 1024 ** 3) : '—');
    set('memory-total', bytes(memory.total_bytes));
    $('memory-meter').style.width = `${memory.total_bytes ? clamp(memory.used_bytes / memory.total_bytes * 100) : 0}%`;
    set('memory-state', memory.pressure || 'Host');
    set('memory-note', number(memory.available_bytes) ? `${bytes(memory.available_bytes)} available to the host` : 'Current host memory usage');
    const load = host.load_average || [];
    set('load-current', fixed(load[0], 2)); set('load-five', fixed(load[1], 2)); set('load-fifteen', fixed(load[2], 2));
    set('cpu-count', host.cpu_count ?? '—');
    set('running-count', inventoryAvailable ? running.length : '—');
    set('configured-running', inventoryAvailable ? running.filter((item) => item.configured).length : '—');
    const tally = running.slice(0, 32).map((item) => element('span', item.configured || item.transient ? '' : 'warning'));
    $('container-tally').replaceChildren(...tally);
    set('unconfigured-summary', !inventoryAvailable ? 'Docker inventory is unavailable' : unmanaged.length ? `${unmanaged.length} unconfigured · review below` : 'No unconfigured containers running');
    $('unconfigured-summary').className = `metric-note ${unmanaged.length ? 'tone-warning' : ''}`;
    set('host-name', host.name || 'Mac mini'); set('host-os', host.os || 'Production host'); set('host-uptime', duration(host.uptime_seconds));
    const dockerDisk = host.docker_disk || {};
    set('docker-storage', number(dockerDisk.allocated_bytes) ? `Docker: ${bytes(dockerDisk.allocated_bytes)} on disk${number(dockerDisk.logical_bytes) ? ` · ${bytes(dockerDisk.logical_bytes)} virtual capacity` : ''}` : 'Docker storage measurement unavailable.');
    const deployNames = { healthy: 'The heartbeat looks good.', running: 'Checking in with the host.', failed: 'The last heartbeat needs a look.', stale: 'The heartbeat is overdue.', unknown: 'Waiting for a recorded heartbeat.' };
    set('deploy-title', deployNames[deploy.status] || deployNames.unknown);
    set('deploy-badge', { healthy: 'Healthy', running: 'In progress', failed: 'Needs attention', stale: 'Overdue', unknown: 'Unknown' }[deploy.status] || 'Unknown');
    $('deploy-badge').className = `badge ${tone(deploy.status)}`;
    set('deploy-message', deploy.message || 'The host checks for deployment updates every minute.');
    set('deploy-checked', relative(deploy.last_run_at)); $('deploy-checked').title = time(deploy.last_run_at);
    set('deploy-success', relative(deploy.last_success_at)); $('deploy-success').title = time(deploy.last_success_at);
    set('deploy-branch', deploy.branch || '—'); set('deploy-commit', deploy.commit ? String(deploy.commit).slice(0, 8) : '—');
    set('application-count', `${applications.length} configured services`);
    renderWarnings(unmanaged, warnings, errors, disk);
    renderApplications(applications);
    renderContainers();
    renderLogSources(data.log_sources || []);
  }
  function renderWarnings(unmanaged, warnings, errors, disk) {
    const messages = [];
    if (unmanaged.length) {
      const node = element('div', 'warning-message');
      node.append(element('strong', '', `${unmanaged.length} running ${unmanaged.length === 1 ? 'container is' : 'containers are'} outside Toolbox.`), element('span', '', unmanaged.map((item) => item.name).join(', ')));
      const link = element('a', '', 'Review inventory ↓'); link.href = '#container-list'; node.append(link); messages.push(node);
    }
    if (disk.level === 'critical') messages.push(element('div', 'warning-message', `Disk capacity is below the deployment safety threshold.${number(disk.minimum_free_bytes) ? ` At least ${bytes(disk.minimum_free_bytes)} must be immediately free.` : ''}`));
    for (const warning of warnings) {
      const message = typeof warning === 'string' ? warning : warning.message || 'A host check needs attention.';
      if (unmanaged.some((item) => message === `Running container ${item.name} is not configured in Toolbox.`)) continue;
      if (disk.level === 'critical' && message === 'Disk capacity is below the deployment safety threshold.') continue;
      messages.push(element('div', 'warning-message', message));
    }
    for (const error of errors) messages.push(element('div', 'warning-message', `${error.source || 'Host check'}: ${error.message || 'Temporarily unavailable'}`));
    $('warnings').replaceChildren(...messages);
  }
  function renderApplications(applications) {
    if (!applications.length) { $('application-list').replaceChildren(element('p', 'empty-state', 'No configured applications were reported.')); return; }
    const cards = applications.map((app) => {
      const card = element('article', 'application-card');
      const external = app.type === 'external';
      const icon = element('span', `app-icon ${external ? 'external' : ''}`, (app.name || '?').slice(0, 1).toUpperCase()); icon.setAttribute('aria-hidden', 'true');
      const info = element('div', 'app-info');
      info.append(element('p', 'app-name', app.name || 'Unnamed service'));
      const type = external ? 'External host' : app.type === 'host' ? 'Host service' : 'Docker';
      const subtitle = external ? (app.description || 'Hosted elsewhere · not checked') : `${type} · ${app.status || 'unknown'}`;
      info.append(element('p', 'app-subtitle', subtitle));
      card.append(icon, info);
      const stateDot = dot(external ? 'unknown' : app.status); stateDot.title = external ? 'Hosted elsewhere' : app.status || 'Unknown'; card.append(stateDot);
      const url = safeUrl(app.url);
      if (url) { const link = element('a', 'app-link', '↗'); link.href = url; link.target = '_blank'; link.rel = 'noopener noreferrer'; link.setAttribute('aria-label', `Open ${app.name}`); card.append(link); }
      return card;
    });
    $('application-list').replaceChildren(...cards);
  }
  function renderContainers() {
    if (snapshot?.errors?.some((error) => error.source === 'Docker inventory')) {
      set('inventory-count', '—'); set('filter-count', '—');
      $('container-list').replaceChildren(element('p', 'empty-state', 'Docker inventory is temporarily unavailable.'));
      return;
    }
    const containers = Array.isArray(snapshot?.containers) ? snapshot.containers : [];
    const unconfigured = containers.filter((item) => item.state === 'running' && !item.configured && !item.transient);
    set('inventory-count', containers.length); set('filter-count', unconfigured.length);
    const focusedRow = document.activeElement?.closest('.container-row');
    const focusedContainer = focusedRow?.dataset.container;
    const focusedLink = document.activeElement?.classList.contains('container-log-link');
    const open = new Set([...$('container-list').querySelectorAll('details[open]')].map((node) => node.dataset.container));
    const list = (filter === 'unconfigured' ? unconfigured : containers).slice().sort((a, b) => Number(b.state === 'running' && !b.configured && !b.transient) - Number(a.state === 'running' && !a.configured && !a.transient) || String(a.name).localeCompare(String(b.name)));
    if (!list.length) { $('container-list').replaceChildren(element('p', 'empty-state', filter === 'unconfigured' ? 'Everything running is accounted for.' : 'No Docker containers were reported.')); return; }
    const rows = list.map((container) => {
      const unmanaged = container.state === 'running' && !container.configured && !container.transient;
      const row = element('details', `container-row ${unmanaged ? 'unconfigured' : ''}`); row.dataset.container = container.name; row.open = open.has(container.name);
      const summary = element('summary');
      const identity = element('div', 'container-identity'); identity.append(element('p', 'container-name', container.name), element('p', 'container-image', container.image || 'Image unavailable'));
      const status = element('div', 'container-status');
      const state = container.health === 'unhealthy' ? 'unhealthy' : container.state || 'unknown';
      status.append(dot(state), document.createTextNode(state));
      if (unmanaged) status.append(badge('Unconfigured', 'warning'));
      else if (container.transient) status.append(badge('Temporary', 'unknown'));
      const cpu = element('div', 'container-number'); cpu.append(element('span', 'mobile-label', 'CPU'), document.createTextNode(number(container.cpu_percent) ? `${fixed(container.cpu_percent, 1)}%` : '—'));
      const memory = element('div', 'container-number'); memory.append(element('span', 'mobile-label', 'Memory'), document.createTextNode(bytes(container.memory_bytes)));
      const meter = element('div', 'metric-mini'); meter.setAttribute('aria-hidden', 'true'); const fill = element('span'); fill.style.width = `${clamp(container.memory_percent)}%`; meter.append(fill); memory.append(meter);
      const expand = element('span', 'expand-mark', '+'); expand.setAttribute('aria-hidden', 'true');
      summary.append(identity, status, cpu, memory, expand);
      const details = element('dl', 'container-details');
      details.append(fact('Network received', bytes(container.network_rx_bytes)), fact('Network sent', bytes(container.network_tx_bytes)), fact('Disk read', bytes(container.block_read_bytes)), fact('Disk written', bytes(container.block_write_bytes)), fact('Memory limit', bytes(container.memory_limit_bytes)), fact('Processes', container.pids ?? '—'), fact('Restarts', container.restarts ?? '—'), fact('Started', container.started_at ? `${relative(container.started_at)} · ${time(container.started_at)}` : '—'), fact('Image', container.image || '—', true), fact('Toolbox service', container.application || (container.transient ? 'Temporary operation' : container.configured ? 'Configured' : 'Unconfigured'), true));
      const logSource = (snapshot.log_sources || []).find((source) => source.id === `container:${container.name}`);
      if (logSource) { const link = element('a', 'container-log-link', 'Read recent logs ↗'); link.href = '#logs'; link.addEventListener('click', () => { $('log-source').value = logSource.id; changeLogSource(); }); details.append(link); }
      row.append(summary, details); return row;
    });
    $('container-list').replaceChildren(...rows);
    if (focusedContainer) {
      const previous = rows.find((row) => row.dataset.container === focusedContainer);
      previous?.querySelector(focusedLink ? '.container-log-link' : 'summary')?.focus({ preventScroll: true });
    }
  }
  function renderLogSources(sources) {
    const old = $('log-source').value;
    const ids = sources.map((source) => source.id);
    const current = [...$('log-source').options].map((option) => option.value);
    if (JSON.stringify(ids) !== JSON.stringify(current)) {
      const options = sources.map((source) => { const option = element('option', '', source.label || source.id); option.value = source.id; return option; });
      $('log-source').replaceChildren(...options);
      if (ids.includes(old)) $('log-source').value = old;
      else if (ids.includes('heartbeat')) $('log-source').value = 'heartbeat';
      $('log-source').disabled = sources.length === 0;
      $('pause-logs').disabled = sources.length === 0;
      if (!sources.length) {
        logRequest?.abort(); logRequest = null; clearTimeout(logTimer); logLoading(false);
        lastLogText = ''; lastLogSource = ''; $('copy-logs').disabled = true;
        set('log-output', 'No log sources are currently available.'); set('log-status', 'Unavailable');
      }
      else if ($('log-source').value !== old) changeLogSource();
    }
  }
  async function refreshStatus() {
    clearTimeout(statusTimer);
    if (!active || !authenticated || document.hidden || !navigator.onLine || statusRequest) return;
    const requestEpoch = epoch;
    const controller = new AbortController(); statusRequest = controller;
    statusLoading(true);
    try {
      const data = await request('/api/status', controller);
      if (requestEpoch !== epoch) return;
      $('connection-notice').hidden = true;
      renderStatus(data);
    } catch (error) {
      if (requestEpoch !== epoch) return;
      if (error instanceof SessionError) sessionExpired();
      else {
        // Access redirects can become a network error before we receive a 401.
        // Clear the previous session's readings even when the cause is unknown.
        clearSensitive();
        overall('Live readings interrupted', 'warning');
        notice('Unable to connect to the host. Previous readings have been cleared. Retrying automatically; sign in again if this continues.', true);
      }
    } finally {
      if (statusRequest === controller) statusRequest = null;
      statusLoading(false);
      if (active && authenticated) statusTimer = setTimeout(refreshStatus, 15000);
    }
  }
  function changeLogSource() {
    logRequest?.abort(); logRequest = null;
    lastLogSource = ''; lastLogText = '';
    $('copy-logs').disabled = true;
    logLoading(false);
    set('log-output', paused ? 'Resume to read this source.' : 'Reading recent output…');
    refreshLogs();
  }
  async function refreshLogs() {
    clearTimeout(logTimer);
    if (!active || !authenticated || paused || document.hidden || !navigator.onLine || logRequest || $('log-source').disabled) return;
    const source = $('log-source').value;
    if (!source) return;
    const requestEpoch = epoch;
    const controller = new AbortController(); logRequest = controller;
    logLoading(true, !lastLogText || lastLogSource !== source);
    try {
      const data = await request(`/api/logs?source=${encodeURIComponent(source)}&lines=100`, controller);
      if (requestEpoch !== epoch || source !== $('log-source').value || controller !== logRequest || paused) return;
      const text = Array.isArray(data.lines) ? data.lines.join('\n') : '';
      if (text !== lastLogText || source !== lastLogSource) {
        $('log-output').textContent = text || 'No recent log output.';
        lastLogText = text; lastLogSource = source;
        if ($('follow-logs').checked) $('log-output').scrollTop = $('log-output').scrollHeight;
      }
      $('copy-logs').disabled = !text;
      set('log-status', `Live · ${time(data.updated_at)}`);
      set('log-detail', `${Array.isArray(data.lines) ? data.lines.length : 0} recent lines${data.truncated ? ' · older output omitted' : ''} · refreshes every 5 seconds`);
    } catch (error) {
      if (requestEpoch !== epoch || controller !== logRequest) return;
      if (error instanceof SessionError) sessionExpired();
      else {
        lastLogText = ''; lastLogSource = ''; $('copy-logs').disabled = true;
        set('log-output', 'Log output is unavailable. Retrying the live connection…');
        set('log-status', 'Unable to refresh · retrying');
      }
    } finally {
      if (logRequest === controller) { logRequest = null; logLoading(false); }
      if (active && authenticated && !paused) logTimer = setTimeout(refreshLogs, 5000);
    }
  }
  function setFilter(value) {
    if (!snapshot) return;
    filter = value;
    ['all', 'unconfigured'].forEach((name) => { $(`filter-${name}`).classList.toggle('selected', name === value); $(`filter-${name}`).setAttribute('aria-pressed', String(name === value)); });
    renderContainers();
  }
  $('filter-all').addEventListener('click', () => setFilter('all'));
  $('filter-unconfigured').addEventListener('click', () => setFilter('unconfigured'));
  $('refresh').addEventListener('click', () => { refreshStatus(); refreshLogs(); });
  $('reconnect').addEventListener('click', () => window.location.reload());
  $('log-source').addEventListener('change', changeLogSource);
  $('pause-logs').addEventListener('click', () => {
    if ($('log-source').disabled) return;
    paused = !paused;
    $('pause-logs').setAttribute('aria-pressed', String(paused));
    set('pause-logs', paused ? 'Resume' : 'Pause');
    if (paused) { clearTimeout(logTimer); logRequest?.abort(); logRequest = null; logLoading(false); set('log-status', 'Paused'); }
    else refreshLogs();
  });
  $('copy-logs').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(lastLogText); set('copy-logs', 'Copied'); }
    catch { set('copy-logs', 'Select to copy'); }
    setTimeout(() => set('copy-logs', 'Copy'), 2000);
  });
  $('follow-logs').addEventListener('change', () => { if ($('follow-logs').checked) $('log-output').scrollTop = $('log-output').scrollHeight; });
  $('sign-out').addEventListener('click', () => {
    active = false; clearSensitive();
    navigator.serviceWorker?.controller?.postMessage({ type: 'CLEAR_TOOLBOX_CACHE' });
  });
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) { refreshStatus(); refreshLogs(); }
    else { clearTimeout(statusTimer); clearTimeout(logTimer); }
  });
  window.addEventListener('pagehide', () => { active = false; clearTimeout(statusTimer); clearTimeout(logTimer); clearSensitive(); });
  window.addEventListener('pageshow', () => { active = true; refreshStatus(); refreshLogs(); });
  window.addEventListener('offline', () => {
    clearSensitive(); overall('The dashboard is offline', 'warning');
    notice('You are offline. Live readings and logs are not saved on this device.');
  });
  window.addEventListener('online', () => { refreshStatus(); refreshLogs(); });
  window.addEventListener('beforeinstallprompt', (event) => { event.preventDefault(); installPrompt = event; $('install-app').hidden = false; });
  $('install-app').addEventListener('click', async () => { if (!installPrompt) return; await installPrompt.prompt(); installPrompt = null; $('install-app').hidden = true; });
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {});
  refreshStatus();
})();
