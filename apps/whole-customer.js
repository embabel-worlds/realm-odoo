/*
 * The Whole Customer — live data at load, per the app contract: the view fetches through
 * realm-odoo's producers each time; nothing is baked in. The AI read is generated on demand,
 * grounded ONLY on the rows the card shows, and labelled as such.
 */
(function () {
  /* The source system's browser-reachable base, for record deep links (demo constant —
     a shipped realm carries this as configuration). Odoo's canonical record URL is
     /odoo/<model>/<id>. */
  const ODOO_BASE = 'http://localhost:8069';
  const odooUrl = (model, id) => ODOO_BASE + '/odoo/' + model + '/' + id;
  /* The <x>Id linking convention: id columns are not displayed — they turn their display
     column into links. Identity travels; names become doors. */
  const ID_MODELS = { customerId: 'res.partner', leadId: 'crm.lead', invoiceId: 'account.move' };
  const ID_LABELS = { customerId: 'customer', leadId: 'opportunity', invoiceId: 'invoice' };

  const cards = document.getElementById('cards');
  const stageSel = document.getElementById('stage');

  const money = (v) => v == null ? '—'
    : '$' + Number(v).toLocaleString(undefined, { maximumFractionDigits: 0 });

  /* Envelope tolerance: the runtime returns {data} (public envelope) or {rows}. */
  const rowsOf = (res) => (res && (res.data || res.rows)) || [];

  async function load() {
    cards.innerHTML = '<div class="o_empty">Loading live Odoo data…</div>';
    let res;
    try {
      res = await embabel.views.invoke('OdooPipelineReceivables', { stage: stageSel.value });
    } catch (e) {
      cards.innerHTML = '<div class="o_empty">Could not reach the world: ' + e.message + '</div>';
      return;
    }
    const rows = rowsOf(res);
    if (!rows.length) {
      cards.innerHTML = '<div class="o_empty">No open opportunities at "' + stageSel.value +
        '" — try another stage.</div>';
      return;
    }
    /* Group per customer: opportunities and invoices both dedupe by name+amount. */
    /* Dedupe by IDENTITY, never by name: real systems (this demo data included) hold
       distinct invoices with the same name AND amount; keying on display fields silently
       drops money. The view returns the ids for exactly this. */
    const byCustomer = new Map();
    for (const r of rows) {
      const c = byCustomer.get(r.customerId) ||
        { id: r.customerId, name: r.customer, email: r.email, opps: new Map(), invoices: new Map() };
      if (r.leadId != null) c.opps.set(r.leadId, { name: r.opportunity, pipeline: r.pipeline });
      if (r.invoiceId != null) c.invoices.set(r.invoiceId, { name: r.invoice, owed: r.owed, due: r.due });
      byCustomer.set(r.customerId, c);
    }
    cards.innerHTML = '';
    for (const [, c] of byCustomer) {
      const name = c.name;
      const pipeline = [...c.opps.values()].reduce((a, b) => a + (b.pipeline || 0), 0);
      const owed = [...c.invoices.values()].reduce((a, b) => a + (b.owed || 0), 0);
      const card = document.createElement('div');
      card.className = 'o_card';
      card.id = 'customer-' + c.id;
      card.innerHTML =
        '<h2>' + name + ' <a class="o_ext" target="_blank" rel="noopener" title="Open in Odoo" href="' +
        odooUrl('res.partner', c.id) + '">\u2197</a> ' + (owed > 0
          ? '<span class="o_pill o_pill_owe">owes ' + money(owed) + '</span>'
          : '<span class="o_pill o_pill_clear">nothing owed</span>') + '</h2>' +
        '<div class="o_mail">' + (c.email || '') + '</div>' +
        '<div class="o_sec">Open opportunities · ' + money(pipeline) + ' pipeline</div>' +
        [...c.opps.values()].map(o =>
          '<div class="o_row"><span>' + o.name + '</span><span class="o_money">' + money(o.pipeline) + '</span></div>').join('') +
        (c.invoices.size
          ? '<div class="o_sec">Unpaid invoices</div>' +
            [...c.invoices.values()].map(i =>
              '<div class="o_row"><span>' + i.name + (i.due ? ' · due ' + i.due : '') +
              '</span><span class="o_money o_owed">' + money(i.owed) + '</span></div>').join('')
          : '') +
        '<div class="o_read"><button class="o_btn o_btn_ghost">AI read</button></div>';
      card.querySelector('.o_read button').addEventListener('click', () => aiRead(card, name, c, pipeline, owed));
      cards.appendChild(card);
    }
  }

  async function aiRead(card, name, c, pipeline, owed) {
    const holder = card.querySelector('.o_read');
    const btn = holder.querySelector('button');
    btn.disabled = true; btn.textContent = 'Reading…';
    const facts =
      'Customer: ' + name + '\n' +
      'Open opportunities: ' + [...c.opps.values()].map(o => o.name + ' (' + money(o.pipeline) + ')').join('; ') + '\n' +
      'Total pipeline: ' + money(pipeline) + '\n' +
      'Unpaid invoices: ' + (c.invoices.size
        ? [...c.invoices.values()].map(i => i.name + ' ' + money(i.owed) + (i.due ? ' due ' + i.due : '')).join('; ')
        : 'none');
    try {
      const out = await gateway.ai.complete({
        prompt: 'You advise a small business owner. From ONLY these facts, write a two-sentence ' +
          'read of this customer relationship — plain words, verdict first — then one line ' +
          '"Next: <the single most useful action>". Facts:\n' + facts,
      });
      const text = typeof out === 'string' ? out : (out.text || out.result || JSON.stringify(out));
      const div = document.createElement('div');
      div.className = 'o_read_out';
      div.textContent = text;
      div.innerHTML += '<span class="o_read_tag">Generated · grounded only on the ' +
        (c.opps.size + c.invoices.size) + ' rows on this card</span>';
      holder.appendChild(div);
      btn.textContent = 'AI read';
      btn.disabled = false;
    } catch (e) {
      btn.disabled = false; btn.textContent = 'AI read';
      alert('AI read failed: ' + e.message);
    }
  }

  const pretty = (k) => k.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, ch => ch.toUpperCase());
  const cell = (k, v) => {
    if (v == null) return '—';
    if (typeof v === 'number' && /owed|amount|revenue|total|pipeline|value/i.test(k)) return money(v);
    return String(v);
  };

  document.getElementById('askBtn').addEventListener('click', async () => {
    const q = document.getElementById('ask').value.trim();
    if (!q) return;
    const out = document.getElementById('askOut');
    out.hidden = false; out.textContent = 'Asking the graph…';
    try {
      /* The admin ask endpoint returns the FULL envelope — rows AND the generated Virtual
         Cypher — where the gateway surface returns rows only. Same origin, same login. */
      const rsp = await fetch('/api/v1/admin/kg/ask', {
        method: 'POST', credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ question: q }),
      });
      const res = await rsp.json();
      const rows = rowsOf(res);
      out.innerHTML = '';
      if (!rows.length) {
        out.textContent = 'No rows. (' + ((res.warnings && res.warnings[0]) || res.error || 'empty is the answer') + ')';
      } else {
        const allCols = Object.keys(rows[0]);
        const idCols = allCols.filter(c => c in ID_MODELS);
        const cols = allCols.filter(c => !(c in ID_MODELS));
        const t = document.createElement('table');
        t.className = 'o_table';
        t.innerHTML = '<thead><tr>' + cols.map(c => '<th>' + pretty(c) + '</th>').join('') + '</tr></thead>';
        const tb = document.createElement('tbody');
        for (const r of rows) {
          const tr = document.createElement('tr');
          for (const c of cols) {
            const td = document.createElement('td');
            if (typeof r[c] === 'number') td.className = 'o_money';
            const idCol = idCols.find(ic => ID_LABELS[ic] === c && r[ic] != null);
            if (idCol) {
              if (idCol === 'customerId') {
                /* In-app drill-down: the entity is already on screen as a card. */
                const jump = document.createElement('a');
                jump.className = 'o_link';
                jump.href = '#customer-' + r[idCol];
                jump.textContent = cell(c, r[c]);
                jump.addEventListener('click', (ev) => {
                  const el = document.getElementById('customer-' + r[idCol]);
                  if (el) {
                    el.classList.add('o_flash');
                    setTimeout(() => el.classList.remove('o_flash'), 1600);
                  } else {
                    /* Not on this pane — the cards show only the selected stage's customers.
                       Degrade to the system of record rather than a dead in-app jump. */
                    ev.preventDefault();
                    window.open(odooUrl('res.partner', r[idCol]), '_blank', 'noopener');
                  }
                });
                td.appendChild(jump);
              } else {
                td.appendChild(document.createTextNode(cell(c, r[c]) + ' '));
              }
              /* And through to the system of record. */
              const ext = document.createElement('a');
              ext.className = 'o_ext'; ext.target = '_blank'; ext.rel = 'noopener';
              ext.title = 'Open in Odoo';
              ext.href = odooUrl(ID_MODELS[idCol], r[idCol]);
              ext.textContent = '\u2197';
              td.appendChild(ext);
            } else {
              td.textContent = cell(c, r[c]);
            }
            tr.appendChild(td);
          }
          tb.appendChild(tr);
        }
        t.appendChild(tb);
        out.appendChild(t);
      }
      if (res.cypher) {
        const det = document.createElement('details');
        det.className = 'o_cypher';
        det.innerHTML = '<summary>Generated Virtual Cypher</summary><pre></pre>';
        det.querySelector('pre').textContent = res.cypher;
        out.appendChild(det);
      }
    } catch (e) { out.textContent = 'Ask failed: ' + e.message; }
  });

  stageSel.addEventListener('change', load);
  load();
})();
