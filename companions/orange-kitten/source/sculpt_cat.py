"""Full volumetric painted sculpture, shaped from the supplied cat's silhouette.

The PNGs are unmodified ImageGen outputs. Texture coordinates project the
painted character onto curved, closed meshes; no planes or billboards are used.
"""
from pathlib import Path
import math, json, subprocess
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parent.parent
SRC=ROOT/'source'
SCALE=.1
PIXELS=400.
CX=760.
BASE=1080.

def catmull(points,samples=8):
    p=np.array(points,float);out=[]
    for i in range(len(p)):
        a,b,c,d=[p[j%len(p)] for j in [i-1,i,i+1,i+2]]
        for t in np.linspace(0,1,samples,endpoint=False):
            out.append(.5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t*t+(-a+3*b-3*c+d)*t**3))
    return np.array(out)

def normal(p,f):
    n=np.zeros_like(p)
    fn=np.cross(p[f[:,1]]-p[f[:,0]],p[f[:,2]]-p[f[:,0]])
    for j in range(3):np.add.at(n,f[:,j],fn)
    return n/np.maximum(1e-12,np.linalg.norm(n,axis=1,keepdims=True))

def world(q,z):return [(q[0]-CX)/PIXELS,(BASE-q[1])/PIXELS,z]

def sculpt(contour,center,depth,backdepth=None,zcenter=0,nrings=38,nose=False):
    outline=catmull(contour);c=np.array(center,float);N=len(outline)
    if backdepth is None:backdepth=depth
    p=[];pixel=[];faces=[];rear=[]
    for side in [1,-1]:
        centerid=len(p)
        p.append(world(c,zcenter+(depth if side>0 else -backdepth)));pixel.append(c)
        ringids=[]
        for ring in range(1,nrings+1):
            if side<0 and ring==nrings:
                ids=frontboundary
            else:
                r=ring/nrings;ids=[]
                for q in outline:
                    xy=c+(q-c)*r
                    dz=(depth if side>0 else backdepth)*math.sqrt(max(0,1-r*r))
                    if side>0 and nose:
                        dz+=.055*math.exp(-((xy[0]-794)/26)**2-((xy[1]-533)/24)**2)
                        dz+=.035*math.exp(-((xy[0]-796)/125)**2-((xy[1]-636)/83)**2)
                    ids.append(len(p));p.append(world(xy,zcenter+side*dz));pixel.append(xy)
                if side>0 and ring==nrings:frontboundary=ids
            if ring==1:
                ff=[[centerid,ids[j],ids[(j+1)%N]] for j in range(N)]
            else:
                prev=ringids[-1]
                ff=[]
                for j in range(N):
                    k=(j+1)%N
                    ff.extend([[prev[j],ids[j],prev[k]],[prev[k],ids[j],ids[k]]])
            # Contours are clockwise in image coordinates; +Y-up reverses that.
            for tri in ff:
                pts=np.array([p[k] for k in tri]);nz=np.cross(pts[1]-pts[0],pts[2]-pts[0])[2]
                if nz*side<0:tri=tri[::-1]
                rear.append(side<0);faces.append(tri)
            ringids.append(ids)
    p=np.array(p);f=np.array(faces);n=normal(p,f)
    assert np.isfinite(p).all() and np.isfinite(n).all()
    return p,f,n,np.array(pixel),np.array(rear)

PARTS=[
    ('Body',[(509,690),(700,756),(882,766),(1032,708),(1082,784),(1108,887),(1100,968),(1050,1030),(932,1054),(816,1057),(692,1065),(596,1045),(511,989),(449,905),(421,814),(442,743)],(779,879),.49,.46,-.16,False),
    ('LeftForeleg',[(486,755),(582,773),(675,848),(729,907),(764,952),(734,996),(663,1016),(600,981),(557,919),(516,871),(476,831)],(618,886),.24,.21,.20,False),
    ('RightForeleg',[(1001,740),(1061,768),(1097,850),(1106,936),(1073,995),(1008,1008),(948,979),(923,932),(941,862)],(1014,882),.24,.21,.22,False),
    ('Tail',[(430,636),(379,661),(322,718),(272,790),(244,869),(249,942),(280,1000),(337,1046),(407,1066),(479,1066),(535,1042),(569,995),(574,948),(561,897),(524,856),(482,833),(449,798),(424,750),(427,690)],(392,866),.39,.30,.08,False),
    ('LeftPaw',[(580,978),(609,944),(658,925),(716,930),(770,954),(799,985),(812,1027),(786,1061),(729,1074),(665,1071),(614,1055),(585,1026)],(695,1009),.235,.18,.39,False),
    ('RightPaw',[(857,977),(889,944),(936,927),(989,930),(1038,949),(1071,979),(1080,1019),(1056,1055),(1002,1072),(944,1075),(890,1061),(861,1030)],(967,1008),.225,.18,.405,False),
    ('LeftEar',[(382,132),(439,139),(522,175),(592,214),(501,277),(431,338),(374,423),(354,347),(347,254),(354,174)],(430,252),.10,.16,-.015,False),
    ('RightEar',[(823,174),(876,108),(951,40),(985,23),(1008,47),(1035,115),(1053,202),(1054,278),(1044,314),(932,233)],(974,170),.11,.17,-.02,False),
    ('Head',[(720,160),(834,167),(942,211),(1039,291),(1105,388),(1141,486),(1140,584),(1107,664),(1050,734),(965,785),(862,817),(752,830),(645,819),(545,794),(462,746),(402,680),(366,599),(354,517),(365,433),(395,355),(449,283),(522,222),(616,180)],(752,492),.71,.68,.045,True),
]

def tup(q):return '('+', '.join(f'{float(x):.7g}' for x in q)+')'
def vec(q):return '['+', '.join(tup(x) for x in q)+']'
def ints(q):return '['+', '.join(str(int(x)) for x in q)+']'

def mat(name,file):
    return f'''        def Material "{name}" {{
            token outputs:surface.connect = </Cat/Looks/{name}/Surface.outputs:surface>
            def Shader "Surface" {{
                uniform token info:id = "UsdPreviewSurface"
                float inputs:roughness = 0.9
                float inputs:metallic = 0
                color3f inputs:diffuseColor.connect = </Cat/Looks/{name}/Color.outputs:rgb>
                color3f inputs:emissiveColor.connect = </Cat/Looks/{name}/PaintLift.outputs:rgb>
                token outputs:surface
            }}
            def Shader "UV" {{
                uniform token info:id = "UsdPrimvarReader_float2"
                string inputs:varname = "st"
                float2 outputs:result
            }}
            def Shader "Color" {{
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @textures/{file}@
                token inputs:sourceColorSpace = "sRGB"
                token inputs:wrapS = "repeat"
                token inputs:wrapT = "clamp"
                float4 inputs:scale = (0.45, 0.45, 0.45, 1)
                float2 inputs:st.connect = </Cat/Looks/{name}/UV.outputs:result>
                float3 outputs:rgb
            }}
            def Shader "PaintLift" {{
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @textures/{file}@
                token inputs:sourceColorSpace = "sRGB"
                token inputs:wrapS = "repeat"
                token inputs:wrapT = "clamp"
                float4 inputs:scale = (0.65, 0.65, 0.65, 1)
                float2 inputs:st.connect = </Cat/Looks/{name}/UV.outputs:result>
                float3 outputs:rgb
            }}
        }}
'''

