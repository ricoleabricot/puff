// Sticky hero card: fades in once the page header scrolls away, shows the course and the section you're reading.
(()=>{
const head=document.querySelector('.head'),main=document.querySelector('main');if(!head||!main)return;
const hs=[...main.querySelectorAll('h2[id]')],intro=head.querySelector('p')?.textContent||'';
document.head.insertAdjacentHTML('beforeend',`<style>
html{scroll-padding-top:150px}
.hero{position:sticky;top:62px;height:0;z-index:4}
.hero>a{display:flex;gap:12px;align-items:center;margin-top:10px;padding:10px 16px;border-radius:16px;background:linear-gradient(135deg,#FFB59C,#F27E5E);color:#fff;text-decoration:none;box-shadow:0 10px 28px rgba(242,126,94,.35);opacity:0;transform:translateY(-10px) scale(.98);pointer-events:none;transition:opacity .35s ease,transform .35s ease}
.hero.in>a{opacity:1;transform:none;pointer-events:auto}
.hero img{width:38px;height:38px;flex:none;filter:drop-shadow(0 3px 6px rgba(58,42,36,.25))}
.hero span{display:block;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.hero .hc{font-size:12px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;opacity:.9}
.hero .hs{font-size:17px;font-weight:700;line-height:1.3;transition:opacity .2s ease,transform .2s ease}
.hero .hs.out{opacity:0;transform:translateY(4px)}
.hero>a>div{min-width:0}
@media(prefers-reduced-motion:reduce){.hero>a,.hero .hs{transition:none}}
</style>`);
const hero=document.createElement('div');hero.className='hero';hero.setAttribute('aria-hidden','true');
hero.innerHTML=`<a href="#"><img src="${head.querySelector('img').src}" alt=""><div><span class="hc"></span><span class="hs"></span></div></a>`;
hero.querySelector('.hc').textContent=head.querySelector('h1').textContent;
main.prepend(hero);
const card=hero.firstChild,hs_=hero.querySelector('.hs');
card.onclick=e=>{e.preventDefault();scrollTo({top:0,behavior:'smooth'})};
let cur=null,t;
const set=txt=>{if(txt===cur)return;const first=cur===null;cur=txt;clearTimeout(t);
  if(first){hs_.textContent=txt;return}
  hs_.classList.add('out');t=setTimeout(()=>{hs_.textContent=txt;hs_.classList.remove('out')},200)};
let q=0;const tick=()=>{q=0;
  hero.classList.toggle('in',head.getBoundingClientRect().bottom<62);
  let h=null;for(const x of hs)if(x.getBoundingClientRect().top<200)h=x;
  set(h?h.textContent:intro)};
addEventListener('scroll',()=>{if(!q)q=requestAnimationFrame(tick)},{passive:true});tick();
})();
