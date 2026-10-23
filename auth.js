import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
const config=window.MEXROUTE_CONFIG;
const client=createClient(config.url,config.key);
const $=s=>document.querySelector(s);
const screen=$('#authScreen'),status=$('#authStatus'),login=$('#googleLogin');
const cash=n=>Number(n||0).toLocaleString('es-MX',{style:'currency',currency:'MXN'});
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let user,profile,routes=[],fuel=[];
login.onclick=async()=>{login.disabled=true;status.textContent='Abriendo Google…';const{error}=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin}});if(error){status.textContent=error.message;login.disabled=false}};
const signout=document.createElement('button');signout.className='logout';signout.textContent='Cerrar sesión';signout.onclick=async()=>{await client.auth.signOut();location.reload()};document.querySelector('header').append(signout);
async function query(table){const{data,error}=await client.from(table).select('*');if(error)throw error;return data||[]}
function empty(el,message){el.innerHTML='';const p=document.createElement('p');p.className='feedback';p.textContent=message;el.append(p)}
function table(el,headers,rows){el.innerHTML='<div class="table-scroll"><table class="history-table"><thead><tr>'+headers.map(h=>'<th>'+escape(h)+'</th>').join('')+'</tr></thead><tbody>'+rows.map(row=>'<tr>'+row.map(v=>'<td>'+escape(v)+'</td>').join('')+'</tr>').join('')+'</tbody></table></div>'}
async function load(){
 $('#quickActions').innerHTML='<button data-go="rutas"><b>Rutas</b><small>Recorridos asignados</small></button><button data-go="gasolina"><b>Gasolina</b><small>Registrar y consultar pagos</small></button><button data-go="evidencias"><b>Evidencias</b><small>Comprobantes de entrega</small></button>';
 document.querySelectorAll('#quickActions [data-go]').forEach(b=>b.onclick=()=>show(b.dataset.go));
 routes=await query('routes');fuel=await query('fuel_payments');
 $('#greeting').textContent='Hola, '+(profile.full_name||user.email);$('#personName').textContent=profile.full_name||user.email;$('#personRole').textContent=profile.role==='admin'?'Administración':'Conductor';$('#roleBadge').textContent=profile.role==='admin'?'ADMINISTRACIÓN':'CONDUCTOR';
 document.querySelector('.environment').textContent='Operación en línea';$('#intro').textContent='Consulta y administra tu operación de Mex Route.';
 document.querySelectorAll('.admin-only').forEach(el=>el.classList.toggle('hidden',profile.role!=='admin'));
 $('#financeCards').innerHTML='<div><small>Rutas visibles</small><b>'+routes.length+'</b></div><div><small>Gasolina registrada</small><b>'+cash(fuel.reduce((a,x)=>a+Number(x.amount),0))+'</b></div><div><small>Por validar</small><b>'+fuel.filter(x=>x.status==='submitted').length+'</b></div>';
 $('#pendingOne').textContent=fuel.filter(x=>x.status==='submitted').length+' pagos de gasolina por validar';$('#pendingOneDetail').textContent='Información registrada en Supabase';$('#pendingTwo').textContent=routes.filter(x=>x.status!=='completed').length+' rutas abiertas';$('#pendingTwoDetail').textContent='Consulta la sección de rutas';
 if(routes.length)table($('#routeList'),['Ruta','Fecha','Estado'],routes.map(x=>[x.route_code,x.scheduled_at,x.status]));else empty($('#routeList'),'Aún no hay rutas asignadas.');
 $('#monthly').textContent=cash(fuel.reduce((a,x)=>a+Number(x.amount),0));$('#fuelCount').textContent=fuel.filter(x=>x.status==='submitted').length;$('#tabPending').textContent=$('#fuelCount').textContent;
 if(fuel.length)table($('#fuelList'),['Fecha','Estación','Litros','Importe','Estado'],fuel.map(x=>[x.occurred_at,x.station,x.liters,cash(x.amount),x.status]));else empty($('#fuelList'),'Aún no hay pagos de gasolina.');
 const select=$('#payRoute');select.innerHTML='<option value="">Sin ruta asociada</option>'+routes.map(x=>'<option value="'+x.id+'">'+escape(x.route_code)+'</option>').join('');
 const ev=await query('evidences');empty($('.evidence-list'),ev.length+' evidencias registradas.');
 if(profile.role==='admin'){
 const people=await query('profiles'),vehicles=await query('vehicles');
 const routeForm=document.createElement('form');routeForm.className='operation-form';routeForm.innerHTML='<label>Código de ruta<input name="code" required></label><label>Fecha<input name="date" type="date" required></label><label>Conductor<select name="driver">'+people.map(p=>'<option value="'+p.id+'">'+escape(p.full_name||p.id)+'</option>').join('')+'</select></label><label>Unidad<select name="vehicle"><option value="">Sin unidad</option>'+vehicles.map(v=>'<option value="'+v.id+'">'+escape(v.plate)+'</option>').join('')+'</select></label><label>Importe de ruta<input name="rate" type="number" min="0" step=".01" required></label><button>Asignar ruta</button>';
 document.querySelector('#rutas .operation-form')?.remove();$('#rutas').append(routeForm);routeForm.onsubmit=async e=>{e.preventDefault();const f=new FormData(routeForm);const{error}=await client.from('routes').insert({route_code:f.get('code'),scheduled_at:f.get('date'),driver_id:f.get('driver'),vehicle_id:f.get('vehicle')||null,route_rate:Number(f.get('rate'))});if(error)alert(error.message);else await load()};
 for(const p of fuel.filter(p=>p.status==='submitted')){const actions=document.createElement('div');actions.textContent=p.station+' · '+cash(p.amount)+' ';for(const [state,label] of [['approved','Aprobar'],['rejected','Rechazar']]){const b=document.createElement('button');b.className='review-btn';b.textContent=label;b.onclick=async()=>{const{error}=await client.from('fuel_payments').update({status:state,reviewed_by:user.id,reviewed_at:new Date().toISOString()}).eq('id',p.id);if(error)alert(error.message);else await load()};actions.append(b)}$('#fuelList').append(actions)}
 }
 if(profile.role==='admin'){
 const history=await query('workbook_history');
 const report=$('#reportes');report.innerHTML='<div class="hero"><h1>Histórico del Excel</h1><p>Consulta de origen por hoja. Los acumulados son referencias y no se suman a los movimientos.</p></div><label>Hoja<select id="historySheet"></select></label><article id="historyRows"></article>';
 const names=[...new Set(history.map(x=>x.sheet))];$('#historySheet').innerHTML=names.map(x=>'<option>'+escape(x)+'</option>').join('');
 const renderHistory=()=>{const records=history.filter(x=>x.sheet===$('#historySheet').value).sort((a,b)=>a.source_row-b.source_row);table($('#historyRows'),['Fila','Datos del archivo'],records.map(x=>[x.source_row,x.values_json.filter(v=>v!==null).join(' · ')]))};$('#historySheet').onchange=renderHistory;renderHistory();
 const costs=await query('period_costs');$('#costos').innerHTML='<div class="hero"><h1>Costos y pagos</h1><p>Los periodos anteriores están disponibles en Histórico del Excel.</p></div><article id="costRows"></article>';if(costs.length)table($('#costRows'),['Categoría','Desde','Hasta','Importe'],costs.map(x=>[x.category,x.period_start,x.period_end,cash(x.amount)]));else empty($('#costRows'),'No hay costos nuevos registrados.');
 }
}
$('#save').onclick=async e=>{e.preventDefault();const amount=Number($('#amount').value),liters=Number($('#liters').value);if(!(amount>0&&liters>0)){alert('Ingresa importe y litros mayores que cero.');return}const route=routes.find(x=>x.id===$('#payRoute').value);const{error}=await client.from('fuel_payments').insert({driver_id:user.id,route_id:route?.id||null,vehicle_id:route?.vehicle_id||null,amount,liters,station:$('#station').value.trim()});if(error){alert(error.message);return}$('#dialog').close();await load()};
try{
 const {data:{session},error}=await client.auth.getSession();if(error)throw error;
 if(session){user=session.user;const{data,error:pError}=await client.from('profiles').select('*').eq('id',user.id).single();if(pError)throw pError;profile=data;await load();screen.classList.add('hidden')}
}catch(error){status.textContent='No se pudo cargar la operación: '+error.message;login.disabled=false}
