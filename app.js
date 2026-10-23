const $=s=>document.querySelector(s);
function show(id){const target=document.getElementById(id);if(!target||target.classList.contains('hidden'))return;document.querySelectorAll('.view').forEach(v=>v.classList.toggle('visible',v.id===id));document.querySelectorAll('nav button,footer button').forEach(b=>b.classList.toggle('active',(b.dataset.go||b.dataset.view)===id));document.querySelector('aside').classList.remove('mobile-open');window.scrollTo({top:0,behavior:'smooth'});document.dispatchEvent(new CustomEvent('mexroute:navigate',{detail:id}))}
document.querySelectorAll('[data-view],[data-go]').forEach(b=>b.onclick=()=>show(b.dataset.go||b.dataset.view));
document.querySelectorAll('.close').forEach(b=>b.onclick=()=>b.closest('dialog').close());
$('.menu').onclick=()=>document.querySelector('aside').classList.toggle('mobile-open');
