const S=[...document.querySelectorAll('.slide')],ch=new BroadcastChannel('puff-deck-'+location.pathname),P=new URLSearchParams(location.search).has('presenter');
let i=Math.min(Math.max(parseInt(location.hash.slice(1)||'1')-1,0),S.length-1);
function show(n,send=true){i=Math.min(Math.max(n,0),S.length-1);
  S.forEach((s,k)=>s.classList.toggle('on',k===i));
  history.replaceState(null,'','#'+(i+1));
  document.getElementById('count').textContent=(i+1)+' / '+S.length;
  document.getElementById('prog').style.width=((i+1)/S.length*100)+'%';
  if(P)present();if(send)ch.postMessage(i)}
function present(){let v=document.querySelector('.pv');if(!v){v=document.createElement('div');v.className='pv';document.body.appendChild(v)}
  const s=S[i],nx=S[i+1];v.innerHTML='<div class="ct">'+(i+1)+' / '+S.length+'</div><h1>'+s.dataset.title+'</h1><div class="nx">Next: '+(nx?nx.dataset.title:'end')+'</div>'+s.querySelector('.notes').innerHTML}
ch.onmessage=e=>show(e.data,false);
document.addEventListener('keydown',e=>{
  if(['ArrowRight','PageDown',' ','Enter'].includes(e.key)){e.preventDefault();show(i+1)}
  else if(['ArrowLeft','PageUp','Backspace'].includes(e.key)){e.preventDefault();show(i-1)}
  else if(e.key==='Home')show(0);else if(e.key==='End')show(S.length-1);
  else if(e.key==='f'||e.key==='F'){document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen()}
  else if((e.key==='p'||e.key==='P')&&document.querySelector('.notes li')){window.open(location.pathname+'?presenter#'+(i+1),'puff-presenter','width=760,height=560')}});
document.addEventListener('click',e=>{if(P||e.target.closest('a,.bar'))return;show(e.clientX>innerWidth/3?i+1:i-1)});
if(P)document.body.classList.add('presenter');
show(i);
