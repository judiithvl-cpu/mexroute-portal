export function monday(date) {
  const day = new Date(date + 'T00:00:00Z');
  day.setUTCDate(day.getUTCDate() - (day.getUTCDay() + 6) % 7);
  return day.toISOString().slice(0, 10);
}

export function summarizeWeek({routes, costs, fuel}) {
  const units = new Map();
  function totals(plate) {
    if (!units.has(plate)) units.set(plate, {completed:0, routes:0, operator:0, gps:0, administration:0, other:0, approved:0, submitted:0, paid:0});
    return units.get(plate);
  }
  const cents = amount => Math.round(Number(amount) * 100);
  for (const route of routes) {
    const unit = totals(route.plate);
    if (route.status === 'completed') {
      unit.completed++;
      unit.routes += cents(route.rate);
    }
    if (route.status === 'cancelled') unit.routes += cents(route.cancellation_rate);
  }
  for (const cost of costs) {
    const key = {operator:'operator',gps:'gps',administration:'administration',settlement_paid:'paid'}[cost.category] || 'other';
    totals(cost.plate)[key] += cents(cost.amount);
  }
  for (const item of fuel) {
    const unit = totals(item.plate);
    if (['approved','submitted'].includes(item.status)) unit[item.status] += cents(item.amount);
  }
  return units;
}

export function setupFleet({client, admin, today, $, field, table, options, submit, write, notify, run, labels, categories, cash, state}) {
  let people = [], assignments = [], loaded = false, request = 0;
  const date = $('#weekStart');
  date.value = monday(today());
  const account = $('#weekAccount');
  const route = $('#routeForm'), cost = $('#costForm'), fuel = $('#fuelForm');
  const fleetForm = $('#fleetAssignment');
  const legacyCost = $('#legacyCostForm');
  const driverAccounts = () => people.filter(person => person.active && person.role === 'driver');
  const title = person => person.full_name ? person.full_name + ' · ' + person.email : person.email;
  const assignment = vehicle => assignments.find(item => item.vehicle_id === vehicle)?.account_email;
  const availableUnits = () => state().vehicles.filter(vehicle => vehicle.active && assignment(vehicle.id));
  const plate = vehicle => vehicle.label ? vehicle.plate + ' · ' + vehicle.label : vehicle.plate;
  const rpc = async (name, params) => {
    const {data,error} = await client.rpc(name, params);
    if (error) throw error;
    return data;
  };

  function routeUnits() {
    const selected = field(route,'driver').value;
    const email = driverAccounts().find(person => person.user_id === selected)?.email;
    options(field(route,'vehicle'), availableUnits().filter(unit => assignment(unit.id) === email), 'id', plate, 'Sin unidad vinculada');
  }

  function fuelUnits() {
    const selected = field(fuel,'driver').value;
    const email = driverAccounts().find(person => person.user_id === selected)?.email;
    options(field(fuel,'vehicle'), availableUnits().filter(unit => assignment(unit.id) === email), 'id', plate, 'Sin unidad');
    field(fuel,'vehicle').disabled = Boolean(field(fuel,'route').value);
  }

  function renderAdmin() {
    if (!admin() || !loaded) return;
    const active = driverAccounts();
    options(field(route,'driver'),active.filter(person => person.user_id),'user_id',title,'Selecciona una cuenta que ya ingresó');
    options(field(fleetForm,'email'),active,'email',title,'Selecciona una cuenta');
    options(field(fleetForm,'vehicle'),state().vehicles.filter(unit => unit.active),'id',plate,'Selecciona una unidad');
    options(field(cost,'vehicle'),availableUnits(),'id',unit => plate(unit) + ' · ' + assignment(unit.id),'Selecciona una unidad');
    options(field(legacyCost,'vehicle'),availableUnits(),'id',unit => plate(unit) + ' · ' + assignment(unit.id),'Selecciona una unidad');
    const unlinked = state().costs.filter(item => !item.fleet_account &&
      monday(item.period_start) === monday(item.period_end));
    options(field(legacyCost,'cost'),unlinked,'id',item =>
      item.period_start + ' · ' + categories[item.category] + ' · ' + cash(item.amount) + ' · ' + (item.notes || 'Sin referencia'),'Selecciona un costo');
    legacyCost.classList.toggle('hidden',!unlinked.length);
    options(account,people.filter(person => person.role === 'driver' || assignments.some(item => item.account_email === person.email)),'email',title,'Selecciona una cuenta');
    table($('#fleetAccounts'),['Cuenta','Nombre','Rol','Estado'],people.map(person => [
      person.email, person.full_name || '—', person.role === 'admin' ? 'Administración' : 'Consulta',
      !person.active ? 'Desactivada' : person.user_id ? 'Activa' : 'Autorizada, pendiente de primer ingreso'
    ]));
    table($('#fleetUnits'),['Unidad','Cuenta asignada'],state().vehicles.map(unit => [plate(unit),assignment(unit.id) || 'Sin asignar']));
    routeUnits();
    fuelUnits();
  }

  async function loadAdmin() {
    if (!admin()) return;
    [people,assignments] = await Promise.all([rpc('admin_list_employee_access'),rpc('admin_fleet_assignments')]);
    loaded = true;
    renderAdmin();
  }

  async function loadWeek() {
    const current = ++request;
    const selected = date.value;
    const email = admin() ? account.value : null;
    const message = $('#weekMessage');
    const details = ['#weekTotals','#weekRoutes','#weekCosts','#weekFuel'];
    for (const selector of details) $(selector).replaceChildren();
    if (admin() && !email) {
      message.textContent = 'Selecciona la cuenta que quieres consultar.';
      return;
    }
    if (!selected || monday(selected) !== selected) {
      message.textContent = 'Selecciona el lunes de la semana.';
      return;
    }
    message.textContent = 'Consultando semana…';
    let data;
    try {
      data = await rpc('fleet_week',{p_start:selected,p_email:email});
    } catch (error) {
      if (current !== request) return;
      message.textContent = 'No se pudo consultar la semana. Usa Actualizar semana para reintentar.';
      throw error;
    }
    if (current !== request) return;
    const totals = summarizeWeek(data);
    message.textContent = totals.size ? 'La tarifa de ruta, los gastos, la gasolina y los pagos registrados se muestran por separado.' : 'No hay movimientos vinculados en esta semana.';
    if (!totals.size) return;
    const sum = {completed:0,routes:0,operator:0,gps:0,administration:0,other:0,approved:0,submitted:0,paid:0};
    const columns = Object.keys(sum);
    const amounts = row => [row.completed,...columns.slice(1).map(key => cash(row[key]/100))];
    for (const row of totals.values()) for (const key of columns) sum[key] += row[key];
    table($('#weekTotals'),['Unidad','Rutas realizadas','Importe de rutas','Operador','GPS','Administración','Otros gastos','Gasolina validada','Gasolina por validar','Pagos registrados'],[
      ...Array.from(totals,([unit,row]) => [unit,...amounts(row)]),['Total de la cuenta',...amounts(sum)]
    ]);
    if (data.routes.length) table($('#weekRoutes'),['Fecha','Unidad','Ruta','Estado','Tarifa','Tarifa de cancelación',...(admin()?['Operador']:[])],
      data.routes.map(row => [row.date,row.plate,row.code,labels[row.status],cash(row.rate),cash(row.cancellation_rate),...(admin()?[row.operator || '—']:[])]));
    if (data.costs.length) table($('#weekCosts'),['Desde','Hasta','Unidad','Concepto','Importe',...(admin()?['Referencia']:[])],
      data.costs.map(row => [row.start,row.end,row.plate,categories[row.category],cash(row.amount),...(admin()?[row.notes || '—']:[])]));
    if (data.fuel.length) table($('#weekFuel'),['Fecha','Unidad','Ruta','Importe','Validación'],
      data.fuel.map(row => [row.date,row.plate,row.route || '—',cash(row.amount),labels[row.status]]));
  }

  $('#employeeForm').onsubmit = event => {
    event.preventDefault();
    submit(event.currentTarget,async form => {
      await rpc('admin_set_fleet_viewer',{p_email:form.get('email'),p_active:form.get('active') === 'yes'});
      await loadAdmin();
      notify(form.get('active') === 'yes' ? 'Correo autorizado para el ingreso con Google.' : 'Acceso desactivado.');
    });
  };
  $('#fleetVehicle').onsubmit = event => {
    event.preventDefault();
    submit(event.currentTarget,async form => {
      await write('vehicles',{plate:form.get('plate').trim().toUpperCase(),label:form.get('label').trim() || null});
      notify('Unidad registrada. Puedes asignarla a una cuenta.');
    });
  };
  fleetForm.onsubmit = event => {
    event.preventDefault();
    submit(event.currentTarget,async form => {
      await rpc('admin_assign_fleet_vehicle',{p_vehicle:form.get('vehicle'),p_email:form.get('email')});
      await loadAdmin();
      notify('Unidad asignada. Sus movimientos anteriores conservan su cuenta.');
    });
  };
  legacyCost.onsubmit = event => {
    event.preventDefault();
    submit(event.currentTarget,async form => {
      const vehicle_id = form.get('vehicle');
      const fleet_account = assignment(vehicle_id);
      if (!fleet_account) throw new Error('Selecciona una unidad asignada.');
      const {data,error} = await client.from('period_costs').update({vehicle_id,fleet_account})
        .eq('id',form.get('cost')).is('fleet_account',null).select('id');
      if (error) throw error;
      if (!data.length) throw new Error('El costo ya se vinculó. Actualiza la información.');
      notify('Costo vinculado a la unidad y su cuenta.');
    });
  };
  field(route,'driver').addEventListener('change',routeUnits);
  field(fuel,'driver').addEventListener('change',fuelUnits);
  field(fuel,'route').addEventListener('change',fuelUnits);
  $('#weekRefresh').onclick = () => run($('#weekRefresh'),loadWeek);
  account.onchange = date.onchange = () => loadWeek().catch(error => notify(error.message,true));

  return {
    loadAdmin, loadWeek, renderAdmin, fuelUnits,
    async createRoute(form) {
      const vehicle = form.get('vehicle') || null;
      const email = assignment(vehicle) || null;
      if (vehicle && !email) throw new Error('Selecciona una unidad asignada a la cuenta.');
      await rpc('admin_create_fleet_route',{p_code:form.get('code'),p_date:form.get('date'),p_driver:form.get('driver'),
        p_vehicle:vehicle,p_rate:Number(form.get('rate')),p_email:email,p_operator:form.get('operator')});
    },
    costLink(form) {
      const vehicle_id = form.get('vehicle');
      const fleet_account = assignment(vehicle_id);
      if (!fleet_account) throw new Error('Selecciona una unidad asignada a una cuenta.');
      return {vehicle_id,fleet_account};
    },
    fuelLink(form,routeRow) {
      const vehicle_id = routeRow ? routeRow.vehicle_id : form.get('vehicle') || null;
      return {vehicle_id,fleet_account:routeRow ? routeRow.fleet_account : assignment(vehicle_id) || null};
    }
  };
}
