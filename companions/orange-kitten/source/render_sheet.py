from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parent.parent
items=[('Front','happy',-.32,.165,0),('ThreeQuarter','happy',0,.165,35),('Side','happy',.32,.165,90),('Back','happy',-.32,-.165,180),('Sleepy','sleepy',0,-.165,0),('Surprised','surprised',.32,-.165,0)]
text='''#usda 1.0
(
 upAxis = "Y"
 metersPerUnit = 1
)
'''
for name,expression,x,y,angle in items:
    text+=f'''def Xform "{name}" (references = @../cat-{expression}-v2.usdz@</Cat>) {{
 double3 xformOp:translate = ({x}, {y}, 0)
 float3 xformOp:rotateXYZ = (0, {angle}, 0)
 uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ"]
}}
'''
text+='''def Camera "Camera" {
 token projection = "orthographic"
 float horizontalAperture = 9.6
 float verticalAperture = 6.4
 float2 clippingRange = (0.001, 100)
 double3 xformOp:translate = (0, 0.132, 1)
 uniform token[] xformOpOrder = ["xformOp:translate"]
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
  token outputs:surface
 }
}
def Mesh "Backdrop" (prepend apiSchemas = ["MaterialBindingAPI"]) {
 uniform token subdivisionScheme = "none"
 point3f[] points = [(-1, -1, -0.22), (1, -1, -0.22), (1, 1, -0.22), (-1, 1, -0.22)]
 int[] faceVertexCounts = [4]
 int[] faceVertexIndices = [0, 1, 2, 3]
 rel material:binding = </BackdropMaterial>
}
'''
scene=ROOT/'source'/'render-sheet.usda';scene.write_text(text)
subprocess.run(['/usr/bin/usdrecord','--camera','Camera','--imageWidth','1800','--disableCameraLight',str(scene),str(ROOT/'actual-model-views-and-expressions.png')],check=True)
