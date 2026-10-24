// Pure calculations shared by the portal and regression tests. No credentials or stored data.
export const numeric = value => typeof value === 'number' && Number.isFinite(value);
export const total = (rows, key) => rows.reduce((sum, row) => sum + (numeric(Number(row[key])) ? Number(row[key]) : 0), 0);
export function periodRows(rows, key, start, end) {
  return rows.filter(row => (!start || row[key] >= start) && (!end || row[key] <= end));
}
export function fuelSummary(rows) {
  const amounts = status => Math.round(total(rows.filter(row => row.status === status), 'amount') * 100) / 100;
  const approved = rows.filter(row => row.status === 'approved');
  const liters = total(approved, 'liters');
  return {approved: amounts('approved'), submitted: amounts('submitted'), rejected: amounts('rejected'), liters,
    price: liters > 0 ? total(approved, 'amount') / liters : null};
}
export function operationAlerts({routes, fuel, evidences}, date) {
  const alerts = [];
  if (fuel.some(payment => /^QA (PRUEBA|RECHAZO) - NO OPERATIVO$/.test(payment.station || '')))
    alerts.push({view:'gasolina', text:'Hay cargas marcadas como prueba NO OPERATIVO. Los totales incluyen esos registros: revisarlos antes de usarlos para contabilidad. No se eliminan automáticamente.'});
  for (const route of routes) {
    if (['assigned', 'in_progress'].includes(route.status) && route.scheduled_at < date)
      alerts.push({view:'rutas', text:`Ruta ${route.route_code}: fecha vencida y aún ${route.status === 'assigned' ? 'sin iniciar' : 'en curso'}.`});
    if (route.status === 'completed' && !evidences.some(e => e.route_id === route.id && e.status === 'approved'))
      alerts.push({view:'evidencias', text:`Ruta ${route.route_code}: completada sin evidencia validada.`});
  }
  for (const payment of fuel.filter(p => p.status === 'submitted')) {
    if (!payment.receipt_path) alerts.push({view:'gasolina', text:`Gasolina del ${payment.occurred_at}: falta comprobante para revisar ${payment.station || 'estación sin nombre'}.`});
    if (!payment.route_id) alerts.push({view:'gasolina', text:`Gasolina del ${payment.occurred_at}: sin ruta vinculada.`});
  }
  return alerts;
}
export function historicalFuel(history) {
  // Only dated detail rows. Never add the workbook's subtotal row or summary sheets.
  const rows = history.filter(row => row.sheet === 'NFG776C' && row.source_row > 1 && /^\d{4}-\d{2}-\d{2}$/.test(row.values_json?.[1]));
  const groups = new Map();
  let missing = 0, mismatched = 0, formulaErrors = 0;
  for (const row of rows) {
    const v = row.values_json, plate = String(v[2] || 'Sin placa').trim().toUpperCase();
    if (plate !== row.sheet) mismatched++;
    if (!numeric(v[5]) || !numeric(v[8]) || v[8] <= 0) missing++;
    formulaErrors += v.filter(value => typeof value === 'string' && /^#(DIV\/0!|REF!|VALUE!|N\/A|NUM!|NAME\?)/.test(value)).length;
    const key = plate + ':' + v[1].slice(0,7);
    if (!groups.has(key)) groups.set(key, {plate, month:v[1].slice(0,7), count:0, amount:0, liters:0, pairedAmount:0, pairedLiters:0, incomplete:0});
    const g = groups.get(key);g.count++;
    if (numeric(v[5])) g.amount += v[5];
    if (numeric(v[8])) g.liters += v[8];
    if (numeric(v[5]) && numeric(v[8]) && v[8] > 0) {g.pairedAmount += v[5];g.pairedLiters += v[8];} else g.incomplete++;
  }
  return {count:rows.length, missing, mismatched, formulaErrors, groups:[...groups.values()].sort((a,b)=>(a.plate+a.month).localeCompare(b.plate+b.month))};
}
export function csvText(rows) {
  const cell = value => {let text = String(value ?? '');if (/^[\s]*[=+@-]/.test(text)) text = "'" + text;return '"'+text.replace(/"/g,'""')+'"';};
  return '\uFEFF' + rows.map(row => row.map(cell).join(',')).join('\r\n');
}
