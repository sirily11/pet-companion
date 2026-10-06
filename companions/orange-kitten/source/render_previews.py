from pathlib import Path
import subprocess
import numpy as np

ROOT=Path(__file__).resolve().parent.parent
PREV=ROOT/'previews'
PREV.mkdir(exist_ok=True)
views=[('happy-front','happy',[0,.132,.65]),('happy-three-quarter','happy',[.38,.23,.57]),('happy-side','happy',[.65,.17,0]),('happy-back','happy',[0,.18,-.65]),('happy-oblique','happy',[-.26,.165,.59]),('sleepy-front','sleepy',[0,.132,.65]),('surprised-front','surprised',[0,.132,.65])]
for name,expression,pos in views:
    eye=np.array(pos);target=np.array([-.015,.132,0]);z=eye-target;z/=np.linalg.norm(z);x=np.cross([0,1,0],z);x/=np.linalg.norm(x);y=np.cross(z,x)
    rows=[[*x,0],[*y,0],[*z,0],[*eye,1]]
    mat='('+', '.join('('+', '.join(str(float(v)) for v in r)+')' for r in rows)+')'
    bc=target-z*.18
    corners=[bc-x*.5-y*.5,bc+x*.5-y*.5,bc+x*.5+y*.5,bc-x*.5+y*.5]
    backdrop='['+', '.join('('+', '.join(str(float(v)) for v in r)+')' for r in corners)+']'
    stage=ROOT/'source'/f'preview-{name}.usda'
    stage.write_text('''#usda 1.0
(
 upAxis = "Y"
 metersPerUnit = 1
)
def Xform "Cat" (references = @../cat-'''+expression+'''-v2.usdz@</Cat>) {}
def Camera "Camera" {
 token projection = "orthographic"
 float horizontalAperture = 3.0
 float verticalAperture = 3.0
 float2 clippingRange = (0.001, 100)
 matrix4d xformOp:transform = '''+mat+'''
 uniform token[] xformOpOrder = ["xformOp:transform"]
}
def DomeLight "Fill" {
 color3f inputs:color = (0.9, 0.85, 0.77)
 float inputs:intensity = 0.7
}
def DistantLight "Key" {
 color3f inputs:color = (1, 0.94, 0.87)
 float inputs:intensity = 2.2
 float inputs:angle = 12
 float3 xformOp:rotateXYZ = (-28, -35, 0)
 uniform token[] xformOpOrder = ["xformOp:rotateXYZ"]
}
def DistantLight "Rim" {
 color3f inputs:color = (0.86, 0.92, 1)
 float inputs:intensity = 1.1
 float3 xformOp:rotateXYZ = (-25, 145, 0)
 uniform token[] xformOpOrder = ["xformOp:rotateXYZ"]
}
def Material "BackdropMaterial" {
 token outputs:surface.connect = </BackdropMaterial/Surface.outputs:surface>
 def Shader "Surface" {
  uniform token info:id = "UsdPreviewSurface"
  color3f inputs:diffuseColor = (0, 0, 0)
  color3f inputs:emissiveColor = (0.956, 0.888, 0.776)
  float inputs:roughness = 1
  token outputs:surface
 }
}
def Mesh "Backdrop" (prepend apiSchemas = ["MaterialBindingAPI"]) {
 uniform token subdivisionScheme = "none"
 point3f[] points = '''+backdrop+'''
 int[] faceVertexCounts = [4]
 int[] faceVertexIndices = [0, 1, 2, 3]
 rel material:binding = </BackdropMaterial>
}
''')
    with (ROOT/'source'/f'render-{name}.log').open('w') as log:
        subprocess.run(['/usr/bin/usdrecord','--camera','Camera','--imageWidth','1000','--disableCameraLight','--enableDomeLightVisibility',str(stage),str(PREV/f'{name}.png')],stdout=log,stderr=log,check=True)
    print(f'Rendered {name}',flush=True)
