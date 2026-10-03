#include "verilated.h"
#include "Vturbo_crash_d4_model.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
  bool quick_mode = false;
constexpr double PI=3.14159265358979323846, FS=47998.875;
constexpr int64_t Q20=1048576, RAIL=18432, Q32_ONE=4294967296LL;
constexpr uint64_t S2688_TICKS_Q32=8948058253ULL;
constexpr int64_t S2688_RECIP_Q32=2061535984LL;
constexpr int S2688_HALF=19456;

struct Mat4 { double v[4][4]{}; };
Mat4 mm(const Mat4&a,const Mat4&b){Mat4 c{};for(int i=0;i<4;i++)for(int j=0;j<4;j++)for(int k=0;k<4;k++)c.v[i][j]+=a.v[i][k]*b.v[k][j];return c;}
Mat4 expm4(const Mat4&m){
    double norm=0;for(int i=0;i<4;i++){double s=0;for(int j=0;j<4;j++)s+=std::fabs(m.v[i][j]);norm=std::max(norm,s);}
    int scale=0;while(norm>0.5){norm*=0.5;scale++;}
    Mat4 x=m;double q=std::ldexp(1.0,-scale);for(int i=0;i<4;i++)for(int j=0;j<4;j++)x.v[i][j]*=q;
    Mat4 sum{},term{};for(int i=0;i<4;i++){sum.v[i][i]=1;term.v[i][i]=1;}
    for(int k=1;k<=96;k++){term=mm(term,x);double t=0;for(int i=0;i<4;i++)for(int j=0;j<4;j++){term.v[i][j]/=k;sum.v[i][j]+=term.v[i][j];t+=std::fabs(term.v[i][j]);}if(t<1e-18)break;}
    for(int k=0;k<scale;k++)sum=mm(sum,sum);return sum;
}
struct Ref3 {
    double ad[3][3]{},bd[3]{},x[3]{},last_mid=0,last_out=0;
    Ref3(double rsh,double cn,double cf){
        const double rs=4700,cs=4.7e-6,rfb=220000,a=1/(rs*cs),b=1/(rfb*cn);
        Mat4 m{};m.v[0][0]=-a;m.v[0][1]=-a;m.v[1][1]=-b;m.v[1][2]=b;
        m.v[2][0]=-1/(rs*cf);m.v[2][1]=(-1/rs-1/rsh+cn*b)/cf;m.v[2][2]=-cn*b/cf;
        m.v[0][3]=a;m.v[2][3]=1/(rs*cf);for(int i=0;i<4;i++)for(int j=0;j<4;j++)m.v[i][j]/=FS;const Mat4 e=expm4(m);
        for(int i=0;i<3;i++){for(int j=0;j<3;j++)ad[i][j]=e.v[i][j];bd[i]=e.v[i][3];}
    }
    double step(int u){double n[3]{};for(int i=0;i<3;i++){n[i]=bd[i]*u;for(int j=0;j<3;j++)n[i]+=ad[i][j]*x[j];}for(int i=0;i<3;i++)x[i]=n[i];last_mid=x[1];last_out=x[1]-x[2];return last_out;}
    std::complex<double> response(double hz)const{
        std::complex<double> z=std::exp(std::complex<double>(0,2*PI*hz/FS)),a[3][4]{};
        for(int i=0;i<3;i++)for(int j=0;j<3;j++)a[i][j]=(i==j?z:0)-ad[i][j];for(int i=0;i<3;i++)a[i][3]=bd[i];
        for(int k=0;k<3;k++){int p=k;for(int i=k+1;i<3;i++)if(std::abs(a[i][k])>std::abs(a[p][k]))p=i;for(int j=k;j<4;j++)std::swap(a[k][j],a[p][j]);auto d=a[k][k];for(int j=k;j<4;j++)a[k][j]/=d;for(int i=0;i<3;i++)if(i!=k){auto f=a[i][k];for(int j=k;j<4;j++)a[i][j]-=f*a[k][j];}}
        return a[1][3]-a[2][3];
    }
};
int64_t mul30(int64_t a,int64_t b){return (a*b)>>30;}
int64_t satrail(int64_t v){return v>RAIL?RAIL:v<-RAIL?-RAIL:v;}
int16_t pcm16(int64_t v){return static_cast<int16_t>(v>32767?32767:v<-32768?-32768:v);}
int32_t as32(int64_t v){if(v>INT32_MAX||v<INT32_MIN)throw std::runtime_error("reference state overflow");return static_cast<int32_t>(v);}
constexpr int32_t MK=-470355346,MP=1073099179,MA=2114745692,MB=1053233859;
constexpr int32_t TK=-101011723,TP=1073375645,TA=2142199170,TB=1068779969;
constexpr int32_t A10=1073221714,A20=1073319829,A50=1073472338,A100=1073573641;
constexpr int32_t AL10=249707401,AL20=405185594,AL50=646832424,AL100=807324680;
constexpr int32_t ICM=4753545,ICT=7130317;
struct Branch{int32_t hp=0,y=0,y2=0,xprev=0,k,p,a,b;Branch(bool m):k(m?MK:TK),p(m?MP:TP),a(m?MA:TA),b(m?MB:TB){}int64_t step(int32_t u){int64_t h=(int64_t)u-xprev+mul30(p,hp);int32_t hn=as32(h);int64_t yy=h-(int64_t)hp+mul30(a,y)-mul30(b,y2);int32_t yn=as32(yy);xprev=u;hp=hn;y2=y;y=yn;return mul30(k,yn);}};
int32_t gain(int64_t v){static const int g[65]={292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,292739,253501,176901,123447,86145,60115,41950,29274,21952,16462,12345,9257,6942,5206,3904,2927,2195,1646,1234,926,694,521,390,293,220,165,123,93,69,52,39,29,25,22,19,16,14,12,11,9,9,9,9,9,9,9,9};v=std::clamp<int64_t>(v,2097152,6291456);int i=std::min<int>(63,(v-2097152)>>16),f=(v-2097152)&65535;return g[i]+((g[i+1]-g[i])*f>>16);}
struct Fixed {
    Branch m{true},t{false};int32_t gm=9,gt=9,lpm=0,lpt=0,alpha=1073741824,aa=0;int zin;
    int64_t om=0,ot=0,im=0,it=0,vm=0,vt=0,ic=0;int16_t rm=0,rt=0,rvM=0,rvT=0,ric=0;
    explicit Fixed(int z):zin(z){if(z==10000){alpha=AL10;aa=A10;}else if(z==20000){alpha=AL20;aa=A20;}else if(z==50000){alpha=AL50;aa=A50;}else if(z==100000){alpha=AL100;aa=A100;}}
    void step(int32_t u,int64_t cm,int64_t ct){om=m.step(u);ot=t.step(u);rm=(int16_t)satrail(om);rt=(int16_t)satrail(ot);if(!zin){lpm=lpt=0;im=rm;it=rt;}else{lpm=as32(mul30(aa,lpm)+mul30(1073741824-aa,rm));lpt=as32(mul30(aa,lpt)+mul30(1073741824-aa,rt));im=mul30(alpha,(int32_t)rm-lpm);it=mul30(alpha,(int32_t)rt-lpt);}vm=(im*gm)>>16;vt=(it*gt)>>16;rvM=(int16_t)satrail(vm);rvT=(int16_t)satrail(vt);ic=-(((int64_t)rvM*ICM)>>20)-(((int64_t)rvT*ICT)>>20);ric=(int16_t)satrail(ic);gm=gain(cm);gt=gain(ct);}
};
constexpr uint32_t AUDIO_INTERVAL_CLOCKS=832;
uint32_t max_d4_scheduler_cycles=0;
void clock(Vturbo_crash_d4_model&d,bool ce){d.sample_ce=ce;d.clk=1;d.eval();d.clk=0;d.eval();}
void reset(Vturbo_crash_d4_model&d){d.clk=0;d.rst_n=0;d.sample_ce=0;d.source_ready=1;d.source_in=0;d.main_control_q20=6291456;d.tail_control_q20=6291456;d.eval();for(int i=0;i<6;i++)clock(d,false);d.rst_n=1;}
void tick(Vturbo_crash_d4_model&d,int16_t s,int64_t cm,int64_t ct){d.source_in=s;d.main_control_q20=cm;d.tail_control_q20=ct;for(uint32_t i=0;i<AUDIO_INTERVAL_CLOCKS-1;i++)clock(d,false);clock(d,true);max_d4_scheduler_cycles=std::max<uint32_t>(max_d4_scheduler_cycles,d.dbg_scheduler_cycles_last);if(d.dbg_scheduler_cycles_last>=AUDIO_INTERVAL_CLOCKS)throw std::runtime_error("D-4 scheduler missed 832-clock deadline");}
struct Err{double mx=0,s2=0;size_t n=0;void add(double e){mx=std::max(mx,std::abs(e));s2+=e*e;n++;}double rms()const{return n?std::sqrt(s2/n):0;}};
std::vector<int16_t> noise(size_t n){std::vector<int16_t>x(n);uint32_t s=0x13579BDF;for(auto&v:x){s=s*1664525u+1013904223u;v=(int16_t)((s>>16)&2047)-1024;}return x;}
bool units(Vturbo_crash_d4_model&d,int zin){
    int64_t c=4194304;const size_t unit_n=quick_mode?512:4096;std::vector<std::vector<int16_t>>vs(4,std::vector<int16_t>(unit_n));vs[0][0]=4096;std::fill(vs[1].begin(),vs[1].end(),4096);for(size_t i=0;i<vs[2].size();i++)vs[2][i]=(int16_t)(900*std::sin(2*PI*819.6*i/FS));vs[3]=noise(unit_n);bool ok=true;
    for(size_t vi=0;vi<vs.size();vi++){reset(d);Ref3 rm(2700,10e-9,10e-9),rt(8200,47e-9,47e-9);Fixed f(zin);Err em,et;int64_t sm=0;for(auto s:vs[vi]){tick(d,s,c,c);f.step(s,c,c);em.add(rm.step(s)-(int32_t)d.main_pin8_raw);et.add(rt.step(s)-(int32_t)d.tail_pin14_raw);sm=std::max<int64_t>(sm,std::abs((int64_t)(int32_t)d.dbg_main_y_state));sm=std::max<int64_t>(sm,std::abs((int64_t)(int32_t)d.dbg_tail_y_state));if((int32_t)d.main_pin8_raw!=f.om||(int32_t)d.tail_pin14_raw!=f.ot||(int16_t)d.main_pin8_rail!=f.rm||(int16_t)d.tail_pin14_rail!=f.rt||(int64_t)d.main_vca_raw!=f.vm||(int64_t)d.tail_vca_raw!=f.vt||(int64_t)d.ic33_raw!=f.ic||(int16_t)d.ic33_rail!=f.ric)ok=false;}std::cout<<"unit["<<vi<<"] exact_double max_main="<<em.mx<<" rms_main="<<em.rms()<<" max_tail="<<et.mx<<" rms_tail="<<et.rms()<<" state_max="<<sm<<"\n";}return ok;
}
double fit_amp(const std::vector<double>&y,const std::vector<double>&s,const std::vector<double>&c){double ss=0,cc=0,sc=0,ys=0,yc=0;for(size_t i=0;i<y.size();i++){ss+=s[i]*s[i];cc+=c[i]*c[i];sc+=s[i]*c[i];ys+=y[i]*s[i];yc+=y[i]*c[i];}double d=ss*cc-sc*sc,a=(ys*cc-yc*sc)/d,b=(yc*ss-ys*sc)/d;return std::sqrt(a*a+b*b);
}
bool frequency_check(Vturbo_crash_d4_model&d){
    bool ok=true; const std::array<double,9> fs={4.57,73.7,132.6,819.6,100,300,1000,4000,8000}; const size_t N=quick_mode?32768:524288,skip=N/2;
    for(double f:fs){Ref3 erM(2700,10e-9,10e-9),erT(8200,47e-9,47e-9);double hmRef=std::abs(erM.response(f)),htRef=std::abs(erT.response(f));int amp=std::clamp<int>((int)std::llround(1024.0/std::max(hmRef,htRef)),64,8192);reset(d);double w=2*PI*f/FS;std::vector<double> ym,yt,xi,si,ci;ym.reserve(N/2);yt.reserve(N/2);xi.reserve(N/2);si.reserve(N/2);ci.reserve(N/2);for(size_t i=0;i<N;i++){int16_t u=(int16_t)std::llround(amp*std::sin(w*i));tick(d,u,4194304,4194304);if(i>=skip){double sn=std::sin(w*i),co=std::cos(w*i);ym.push_back((int32_t)d.main_pin8_raw);yt.push_back((int32_t)d.tail_pin14_raw);xi.push_back(u);si.push_back(sn);ci.push_back(co);}}double hm=fit_amp(ym,si,ci)/fit_amp(xi,si,ci),ht=fit_amp(yt,si,ci)/fit_amp(xi,si,ci),em=20*std::log10(hm/hmRef),et=20*std::log10(ht/htRef);std::cout<<"freq_error "<<f<<"Hz amp="<<amp<<" hm="<<hm<<" hm_ref="<<hmRef<<" ht="<<ht<<" ht_ref="<<htRef<<" main_db="<<em<<" tail_db="<<et<<"\n";ok&=std::abs(em)<1.5&&std::abs(et)<1.5;}return ok;
}
bool long_run(Vturbo_crash_d4_model&d,int zin){
    const size_t N=quick_mode?20000:300000;const int64_t c=4194304;Fixed f(zin);reset(d);uint32_t s=0x13579BDF;int64_t maxState=0,maxRaw=0;bool ok=true;for(size_t i=0;i<N;i++){s=s*1664525u+1013904223u;int16_t u=(s&0x80000000u)?19456:-19456;tick(d,u,c,c);f.step(u,c,c);maxState=std::max(maxState,std::abs((int64_t)(int32_t)d.dbg_main_hp_state));maxState=std::max(maxState,std::abs((int64_t)(int32_t)d.dbg_main_y_state));maxState=std::max(maxState,std::abs((int64_t)(int32_t)d.dbg_tail_hp_state));maxState=std::max(maxState,std::abs((int64_t)(int32_t)d.dbg_tail_y_state));maxRaw=std::max(maxRaw,std::abs((int64_t)(int32_t)d.main_pin8_raw));maxRaw=std::max(maxRaw,std::abs((int64_t)(int32_t)d.tail_pin14_raw));if((int32_t)d.main_pin8_raw!=f.om||(int32_t)d.tail_pin14_raw!=f.ot||(int64_t)d.main_vca_raw!=f.vm||(int64_t)d.tail_vca_raw!=f.vt||(int64_t)d.ic33_raw!=f.ic)ok=false;}std::cout<<"long_run samples="<<N<<" fixedpoint="<<(ok?"PASS":"FAIL")<<" max_state="<<maxState<<" max_pin_raw="<<maxRaw<<" signed32_bound="<<(maxState<INT32_MAX?"PASS":"FAIL")<<"\n";return ok;
}bool replay(Vturbo_crash_d4_model&d){auto in=noise(quick_mode?2048:12000);std::vector<std::array<int64_t,8>>a,b;auto run=[&](auto&o){reset(d);for(auto s:in){tick(d,s,4194304,4194304);o.push_back({(int64_t)(int32_t)d.main_pin8_raw,(int64_t)(int32_t)d.tail_pin14_raw,(int64_t)(int16_t)d.main_pin8_rail,(int64_t)(int16_t)d.tail_pin14_rail,(int64_t)(int64_t)d.main_vca_raw,(int64_t)(int64_t)d.tail_vca_raw,(int64_t)(int64_t)d.ic33_raw,(int64_t)(int16_t)d.ic33_rail});}};run(a);run(b);return a==b;}
void fft(std::vector<std::complex<double>>&a){size_t n=a.size();for(size_t i=1,j=0;i<n;i++){size_t bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j)std::swap(a[i],a[j]);}for(size_t l=2;l<=n;l<<=1){auto wl=std::polar(1.0,-2*PI/l);for(size_t i=0;i<n;i+=l){std::complex<double>w(1);for(size_t j=0;j<l/2;j++){auto u=a[i+j],v=a[i+j+l/2]*w;a[i+j]=u+v;a[i+j+l/2]=u-v;w*=wl;}}}}
double band(const std::vector<int16_t>&x,double lo,double hi){size_t n=1;while(n<x.size())n<<=1;std::vector<std::complex<double>>a(n);for(size_t i=0;i<x.size();i++)a[i]=x[i];fft(a);double z=0;for(size_t k=0;k<=n/2;k++){double f=k*FS/n;if(f>=lo&&f<hi)z+=std::norm(a[k]);}return z/n;}
struct SG{uint32_t s=0x0B5E7,ph=0;int16_t next(){uint64_t total=(uint64_t)ph+S2688_TICKS_Q32;uint8_t ticks=total>>32;uint32_t np=total;auto ln=[](uint32_t x){uint32_t f=((x>>16)^(x>>13))&1;return (((x&0xffff)<<1)&0x1ffff)|f;};int64_t area=((s>>16)&1)?Q32_ONE-ph:-(Q32_ONE-ph);uint32_t w=s;for(uint8_t t=1;t<=3;t++)if(t<=ticks){w=ln(w);int64_t dd=t<ticks?Q32_ONE:np;area+=((w>>16)&1)?dd:-dd;}s=w;ph=np;int64_t av=((__int128)area*S2688_RECIP_Q32)>>48;return (int16_t)std::clamp<int64_t>((av*S2688_HALF)>>16,-S2688_HALF,S2688_HALF);}};
int16_t pre(int16_t in,int64_t&lp){int64_t n=in,np=lp+((n-lp)*(Q20-1048430)>>20);lp=np;return pcm16(((n-np)*(-356516))>>20);}
void write_wav(const std::string&p,const std::vector<int16_t>&x){std::ofstream f(p,std::ios::binary);auto w16=[&](uint16_t v){f.put(v);f.put(v>>8);};auto w32=[&](uint32_t v){w16(v);w16(v>>16);};uint32_t bytes=(uint32_t)x.size()*2;f.write("RIFF",4);w32(36+bytes);f.write("WAVEfmt ",8);w32(16);w16(1);w16(1);w32((uint32_t)FS);w32((uint32_t)FS*2);w16(2);w16(16);f.write("data",4);w32(bytes);for(auto v:x)w16((uint16_t)v);}
struct M{int64_t peak=0;long double s2=0;size_t clip=0,above=0,trans=0;};
void add(M&m,int64_t raw,int16_t rail,bool first,int16_t prev){m.peak=std::max<int64_t>(m.peak,(int64_t)std::llabs(raw));m.s2+=(long double)raw*raw;if(std::llabs((int64_t)rail)>=RAIL)m.clip++;if(std::llabs(raw)>=2896)m.above++;if(!first&&((prev==RAIL&&rail==-RAIL)||(prev==-RAIL&&rail==RAIL)))m.trans++;}
void show(const char*n,const M&m,size_t N){std::cout<<n<<" peak="<<m.peak<<" rms="<<std::sqrt((double)(m.s2/N))<<" rail_duty="<<(100.0*m.clip/N)<<"% above0.5Vrms="<<(100.0*m.above/N)<<"%";}
int sweep(Vturbo_crash_d4_model&d,int zin,const std::string&dir){
    const size_t N=(size_t)(1.5*FS),nm=3500,nt=350;reset(d);SG sg;int64_t lp=0,env=5242880,c43=0;Ref3 rm(2700,10e-9,10e-9),rt(8200,47e-9,47e-9);M src,mmid,tmid,pm,pt,im,it,vm,vt,ic;std::vector<int16_t>out;out.reserve(N);int16_t prev=0;bool first=true;
    for(size_t i=0;i<N;i++){int16_t src0=sg.next(),s=pre(src0,lp);bool qm=i<nm,qt=i>=nm&&i<nm+nt;int64_t cm=(5242880+env)>>1,ct=std::clamp<int64_t>((4055649LL<<1)-c43,0,6291456);tick(d,s,cm,ct);rm.step(s);rt.step(s);add(src,s,s,first,prev);add(mmid,(int64_t)std::llround(rm.last_mid),0,true,0);add(tmid,(int64_t)std::llround(rt.last_mid),0,true,0);add(pm,(int32_t)d.main_pin8_raw,(int16_t)d.main_pin8_rail,first,prev);add(pt,(int32_t)d.tail_pin14_raw,(int16_t)d.tail_pin14_rail,first,prev);add(im,(int16_t)d.ic29_main_input,(int16_t)d.ic29_main_input,first,prev);add(it,(int16_t)d.ic29_tail_input,(int16_t)d.ic29_tail_input,first,prev);add(vm,(int64_t)d.main_vca_raw,(int16_t)d.main_vca_rail,first,prev);add(vt,(int64_t)d.tail_vca_raw,(int16_t)d.tail_vca_rail,first,prev);add(ic,(int64_t)d.ic33_raw,(int16_t)d.ic33_rail,first,prev);out.push_back(d.ic33_rail);prev=d.ic33_rail;first=false;if(qm)env=(64918*env+618*838861)>>16;else env=(16777047*env+169*5242880LL)>>24;if(qt)c43+=((5242880-c43)*(Q20-1038886)>>20);else c43-=((c43*(Q20-1048573))>>20);}
    std::string tag=zin==0?"highz":"zin"+std::to_string(zin),path=dir+"/turbo_crash_d4_"+tag+"_0_1500ms.wav";write_wav(path,out);std::cout<<std::fixed<<std::setprecision(3)<<"sweep zin="<<(zin?std::to_string(zin):"high-Z")<<" wav="<<path<<"\n";show("source",src,N);std::cout<<" ";show("midM",mmid,N);std::cout<<" ";show("midT",tmid,N);std::cout<<"\n";show("pin8",pm,N);std::cout<<" ";show("pin14",pt,N);std::cout<<"\n";show("ic29M",im,N);std::cout<<" ";show("ic29T",it,N);std::cout<<"\n";show("vcaM",vm,N);std::cout<<" ";show("vcaT",vt,N);std::cout<<"\n";show("ic33",ic,N);std::cout<<" rail_transitions="<<ic.trans<<" band0_1k="<<band(out,0,1000)<<" band1_8k="<<band(out,1000,8000)<<"\n";return 0;
}
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv); // Production default is the empirical 10K MB4391 loading assumption; pass 0/20K/50K/100K for diagnostics.
int zin=argc>1?std::stoi(argv[1]):10000;std::string dir=argc>2?argv[2]:"sim/out/turbo_crash_d4_diag";quick_mode=argc>3&&std::string(argv[3])=="quick";Vturbo_crash_d4_model d;bool u=units(d,zin),r=replay(d),fr=frequency_check(d),lr=long_run(d,zin);std::cout<<"unit fixedpoint="<<(u?"PASS":"FAIL")<<" reset_replay="<<(r?"PASS":"FAIL")<<" frequency="<<(fr?"PASS":"FAIL")<<" long_run="<<(lr?"PASS":"FAIL")<<"\n";std::cout<<"max_scheduler_clocks="<<max_d4_scheduler_cycles<<" interval="<<AUDIO_INTERVAL_CLOCKS<<"\n";if (!(u&&r&&fr&&lr)) return 1;if (quick_mode) return 0;return sweep(d,zin,dir);}
