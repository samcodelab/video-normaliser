/* Audit-only CPU renderer: Rec.709 inverse transfer, area-averaged thumbnails.
 * This deliberately does not claim equivalence to Core Image Lanczos filtering
 * or its colour management. Apply each field to the current frame only. */
#include <math.h>
#include <stdint.h>
void sample(const uint8_t *rgb,int w,int h,float *out){
 double lut[256];for(int i=0;i<256;i++){double v=i/255.;lut[i]=v<.081?v/4.5:pow((v+.099)/1.099,1/.45);}
 for(int y=0;y<56;y++)for(int x=0;x<96;x++){
 int x0=x*w/96,x1=(x+1)*w/96,y0=y*h/56,y1=(y+1)*h/56;
 double s[3]={0};for(int yy=y0;yy<y1;yy++)for(int xx=x0;xx<x1;xx++)for(int c=0;c<3;c++)s[c]+=lut[rgb[(yy*w+xx)*3+c]];
 for(int c=0;c<3;c++)out[(y*96+x)*3+c]=s[c]/((x1-x0)*(y1-y0));}}
void render(uint8_t *rgb,int w,int h,const double *field,double global){
 double lut[256];for(int i=0;i<256;i++){double v=i/255.;lut[i]=v<.081?v/4.5:pow((v+.099)/1.099,1/.45);}
 for(int y=0;y<h;y++){double py=(y+.5)/h*5;int iy=fmin(4,(int)py);double fy=py-iy;
 for(int x=0;x<w;x++){double px=(x+.5)/w*8;int ix=fmin(7,(int)px);double fx=px-ix;
 double ev=field[iy*9+ix]*(1-fx)*(1-fy)+field[iy*9+ix+1]*fx*(1-fy)+field[(iy+1)*9+ix]*(1-fx)*fy+field[(iy+1)*9+ix+1]*fx*fy;
 double gain=exp2(fmax(-2,fmin(2,global+ev))),p[3],peak=0;for(int c=0;c<3;c++){p[c]=lut[rgb[(y*w+x)*3+c]];peak=fmax(peak,p[c]);}
 if(gain>1 && peak>0)gain=fmin(gain,fmax(1,.995/peak));
 for(int c=0;c<3;c++){double v=p[c]*gain;double enc=v<.018?4.5*v:1.099*pow(v,.45)-.099;rgb[(y*w+x)*3+c]=fmax(0,fmin(255,round(enc*255)));}}}}
