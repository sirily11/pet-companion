"""Bake the painted references around the closed 3D surfaces.

The ImageGen artwork remains untouched. This is material baking for the
sculpture: a continuous UV skin blends the front and reverse near the sides.
"""
from pathlib import Path
import math, sys, subprocess, json
import numpy as np
from PIL import Image
from sculpt_cat import ROOT,SRC,SCALE,PARTS,catmull,sculpt,mat,vec,ints

TEX=SRC/'textures'

def sm(a,b,x):
    t=np.clip((x-a)/(b-a),0,1)
    return t*t*(3-2*t)

def linear(rgb):
    q=rgb.astype(np.float32)/255
    return np.where(q<=.04045,q/12.92,((q+.055)/1.055)**2.4)

def load(name):
    im=np.array(Image.open(TEX/name))
    return linear(im[:,:,:3]),im[:,:,3].astype(np.float32)/255

front=load('front-clean.png')
back=load('back-clean.png')

def sample(image,xy,center):
    color,alpha=image;h,w=alpha.shape
    q=xy.astype(np.float32).copy()
    out=np.zeros((*q.shape[:-1],3),np.float32)
    todo=np.ones(q.shape[:-1],bool)
    for j in range(14):
        ix=np.clip(q[...,0],0,w-1);iy=np.clip(q[...,1],0,h-1)
        x0=np.floor(ix).astype(np.int32);y0=np.floor(iy).astype(np.int32)
        x1=np.minimum(x0+1,w-1);y1=np.minimum(y0+1,h-1)
        fx=ix-x0;fy=iy-y0
        rgb=np.zeros_like(out);aa=np.zeros_like(todo,dtype=np.float32)
        for x,y,weight in [(x0,y0,(1-fx)*(1-fy)),(x1,y0,fx*(1-fy)),(x0,y1,(1-fx)*fy),(x1,y1,fx*fy)]:
            wt=weight*alpha[y,x];aa+=wt
            rgb+=color[y,x]*wt[...,None]
        valid=(aa>.93)&todo
        out[valid]=(rgb/np.maximum(aa[...,None],1e-6))[valid]
        todo&=~valid
        if not todo.any():break
        q[todo]=np.array(center)+(q[todo]-np.array(center))*.91
    if todo.any():out[todo]=linear(np.array([255,190,126]))
    return out

def reverse(xy,part):
    q=xy.copy()
    if part=='Head':
        q[...,0]=665-(q[...,0]-752)*.96
        q[...,1]=443+(q[...,1]-492)*.88
        center=(665,443)
    elif 'Ear' in part:
        q[...,0]=1407-q[...,0];q[...,1]+=10
        c=np.mean(q,axis=(0,1));center=tuple(c)
    else:
        q[...,0]=660-(q[...,0]-780)*.94;q[...,1]-=7
        c=np.mean(q,axis=(0,1));center=tuple(c)
    return q,center

def bake(name,outline,center,expression):
    suffix=expression if name=='Head' else 'shared-v2'
    output=TEX/f'{name.lower()}-{suffix}-skin.png'
    if name!='Head' and output.exists():return output.name
    width,height=(2048,1024) if name=='Head' else (1024,512)
    N=len(outline)
    t=np.arange(width,dtype=np.float32)/width*N
    j=np.floor(t).astype(int);fract=t-j
    rim=outline[j]*(1-fract[:,None])+outline[(j+1)%N]*fract[:,None]
    result=np.zeros((height,width,3),np.uint8)
    exp=load(f'front-{expression}.png')
    for start in range(0,height,64):
        end=min(start+64,height)
        phi=((np.arange(start,end,dtype=np.float32)+.5)/height*math.pi)[:,None]
        r=np.sin(phi)[...,None]
        # A small texture gutter removes transparent antialiasing artifacts.
        xy=np.array(center)+(rim[None,:,:]-np.array(center))*r*.978
        fc=sample(front,xy,center)
        if name=='Head':
            expression_color=sample(exp,xy,center)
            x=xy[...,0];y=xy[...,1]
            mask=sm(465,490,x)*(1-sm(1055,1080,x))*sm(300,325,y)*(1-sm(675,700,y))
            fc=fc*(1-mask[...,None])+expression_color*mask[...,None]
        rearxy,rearc=reverse(xy,name)
        rc=sample(back,rearxy,rearc)
        if name=='Body' or 'Foreleg' in name or 'Paw' in name:
            # The reverse reference shows the cream tail in front of the body.
            # Keep that paint on the tail mesh instead of duplicating its tip
            # onto the body that sits behind it.
            occluded=(rc[...,1]>.72)&(rc[...,2]>.50)
            clear=rearxy.copy();clear[...,0]=660
            clean=sample(back,clear,(660,890))
            rc[occluded]=clean[occluded]
        # Side paint is a continuous 60-degree transition, without a seam.
        mix=sm(math.pi/3,math.pi*2/3,phi)[...,None]
        rgb=fc*(1-mix)+rc*mix
        rgb=np.where(rgb<=.0031308,rgb*12.92,1.055*np.maximum(rgb,0)**(1/2.4)-.055)
        result[start:end]=np.uint8(np.clip(rgb,0,1)*255+.5)
    # v increases upward in USD; top of the PNG is the front pole (v=1).
    Image.fromarray(result).save(output)
    return output.name

def mesh_uv(N,rings,pcount,f):
    uv=[]
    uv.append([.5,1])
    for k in range(1,rings+1):
        v=1-math.asin(k/rings)/math.pi
        for j in range(N):uv.append([j/N,v])
    uv.append([.5,0])
    for k in range(1,rings):
        v=math.asin(k/rings)/math.pi
        for j in range(N):uv.append([j/N,v])
    uv=np.array(uv)
    assert len(uv)==pcount
    uv=uv[f].copy()
    # Duplicate UV coordinates across the longitude seam, preserving topology.
    for tri in uv:
        if tri[:,0].max()-tri[:,0].min()>.5:tri[tri[:,0]<.5,0]+=1
        pole=(tri[:,1]==0)|(tri[:,1]==1)
        if pole.any():tri[pole,0]=tri[~pole,0].mean()
    return uv.reshape(-1,2)

def build(expression):
    geometries=[];materials=[];stats=[]
    for name,contour,center,dep,bdep,zc,nose in PARTS:
        rings=72 if name=='Head' else 48
        p,f,n,px,rear=sculpt(contour,center,dep,bdep,zc,nrings=rings,nose=nose)
        outline=catmull(contour)
        filename=bake(name,outline,center,expression)
        materials.append(mat(name,filename))
        uv=mesh_uv(len(outline),rings,len(p),f)
        p*=SCALE
        geometries.append(f'''    def Mesh "{name}" (prepend apiSchemas = ["MaterialBindingAPI"]) {{
        uniform token subdivisionScheme = "none"
        bool doubleSided = false
        point3f[] points = {vec(p)}
        int[] faceVertexCounts = {ints([3]*len(f))}
        int[] faceVertexIndices = {ints(f.ravel())}
        normal3f[] normals = {vec(n)} (interpolation = "vertex")
        texCoord2f[] primvars:st = {vec(uv)} (interpolation = "faceVarying")
        float3[] extent = {vec([p.min(axis=0),p.max(axis=0)])}
        rel material:binding = </Cat/Looks/{name}>
    }}
''')
        stats.append({'name':name,'vertices':len(p),'triangles':len(f),'skin':filename})
    stage='''#usda 1.0
(
 defaultPrim = "Cat"
 upAxis = "Y"
 metersPerUnit = 1
 documentation = "Painted reference-shaped volumetric kitten. Static pose and painted facial expression; approximately 26 cm tall."
)
def Xform "Cat" (kind = "component") {
    def Scope "Looks" {
'''+''.join(materials)+'    }\n'+''.join(geometries)+'}\n'
    a=SRC/f'cat-{expression}-v2.usda';c=SRC/f'cat-{expression}-v2.usdc';u=ROOT/f'cat-{expression}-v2.usdz'
    a.write_text(stage)
    subprocess.run(['/usr/bin/usdcat',str(a),'-o',str(c)],check=True)
    subprocess.run(['/usr/bin/usdzip','--arkitAsset',str(c),str(u)],check=True)
    subprocess.run(['/usr/bin/usdchecker','--arkit','--strict',str(u)],check=True)
    (SRC/f'stats-{expression}.json').write_text(json.dumps(stats,indent=2))
    print('Exported',expression,sum(x['triangles'] for x in stats),'triangles',flush=True)

if __name__=='__main__':
    for expression in sys.argv[1:] or ['happy','sleepy','surprised']:build(expression)
