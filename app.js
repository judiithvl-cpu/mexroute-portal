const $=s=>document.querySelector(s);
function show(id){document.querySelectorAll('.view').forEach(v=>v.classList.toggle('visible',v.id===id));document.querySelectorAll('nav button,footer button').forEach(b=>b.classList.toggle('active',(b.dataset.go||b.dataset.view)===id));window.scrollTo({top:0,behavior:'smooth'})}
document.querySelectorAll('[data-view],[data-go]').forEach(b=>b.onclick=()=>show(b.dataset.go||b.dataset.view));
$('#openPay').onclick=()=>$('#dialog').showModal();$('.close').onclick=e=>{e.preventDefault();$('#dialog').close()};
$('.menu').onclick=()=>document.querySelector('aside').classList.toggle('mobile-open');
