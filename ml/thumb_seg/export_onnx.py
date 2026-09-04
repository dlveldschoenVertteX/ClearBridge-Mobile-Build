"""Export a trained thumb_seg checkpoint to ONNX, matching the exact I/O
contract sfm_pipeline._segment_via_ml_model expects (see model.py's own
docstring): input (1,1,256,256) float32 named 'input', output (1,1,256,256)
float32 raw logits named 'logits'.

Usage: python export_onnx.py <checkpoint.pt> <out.onnx>
"""
import sys
import torch
from model import ThumbSegUNet

def main():
    ckpt_path, out_path = sys.argv[1], sys.argv[2]
    ckpt = torch.load(ckpt_path, map_location='cpu')
    model = ThumbSegUNet()
    model.load_state_dict(ckpt['model'])
    model.eval()
    dummy = torch.zeros(1, 1, 256, 256, dtype=torch.float32)
    torch.onnx.export(
        model, dummy, out_path,
        input_names=['input'], output_names=['logits'],
        dynamic_axes=None, opset_version=13,
    )
    print('exported', out_path, 'from checkpoint epoch', ckpt.get('epoch'),
          'val_loss', ckpt.get('val_loss'))

if __name__ == '__main__':
    main()
