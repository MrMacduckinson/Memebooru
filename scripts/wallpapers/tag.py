#!/usr/bin/env python3
"""Local CLIP suggestions + measured colours and dimensions; no images leave this machine."""
import argparse
import colorsys
import json
from pathlib import Path
from PIL import Image, ImageOps, ImageFile
from download import write_json

# English prompts are used by CLIP; the collection's searchable tags are Russian.
SUBJECTS = {
 'небо':'blue sky', 'облака':'clouds', 'трава':'green grass', 'деревья':'trees', 'лес':'a forest',
 'горы':'mountains', 'холмы':'rolling hills', 'озеро':'a lake', 'океан':'the ocean', 'пляж':'a beach',
 'река':'a river', 'водопад':'a waterfall', 'вода':'water', 'подводный_мир':'an underwater scene',
 'рыбы':'fish', 'дельфины':'dolphins', 'пузырьки':'bubbles', 'капли':'water droplets',
 'листья':'leaves', 'цветы':'flowers', 'бабочки':'butterflies', 'птицы':'birds', 'животные':'animals',
 'снег':'snow', 'лёд':'ice', 'пустыня':'a desert', 'камни':'rocks', 'остров':'an island',
 'солнце':'the sun', 'закат':'a sunset', 'луна':'the moon', 'звёзды':'stars', 'космос':'outer space',
 'планеты':'planets', 'земной_шар':'a globe of planet Earth', 'радуга':'a rainbow', 'туман':'fog',
 'город':'a city skyline', 'небоскрёбы':'skyscrapers', 'архитектура':'buildings', 'мост':'a bridge',
 'дорога':'a road', 'транспорт':'vehicles', 'самолёт':'an airplane', 'автомобиль':'a car',
 'круги':'circles', 'сферы':'glossy spheres', 'кубы':'cubes', 'волны':'abstract waves',
 'линии':'flowing lines', 'спирали':'spirals', 'фрактал':'a fractal', 'свечение':'glowing light',
 'градиент':'a smooth color gradient', 'стекло':'transparent glass', 'металл':'shiny metal',
 'текстура':'a textured surface', 'узор':'a repeating pattern', 'геометрия':'geometric shapes',
 'ленты':'flowing ribbons', 'блики':'light reflections', 'технологии':'futuristic technology',
 'компьютер':'a computer', 'логотип':'a logo', 'windows':'the Windows logo', 'apple':'the Apple logo',
 'надписи':'typography and text', 'сердца':'hearts', 'музыка':'musical notes', 'ноты':'sheet music',
 'аниме':'anime characters', 'девушка':'an illustrated girl', 'персонажи':'cartoon characters',
 'лиса':'a cartoon fox', 'вокалоид':'Hatsune Miku', 'меха':'anime robots', 'фэнтези':'a fantasy world',
 'сакура':'cherry blossoms', 'бамбук':'bamboo', 'пальмы':'palm trees', 'подсолнухи':'sunflowers',
 'розы':'roses', 'ромашки':'daisies', 'лотос':'lotus flowers', 'фрукты':'fruit',
 'мох':'moss', 'поле':'a field', 'сад':'a garden', 'ветки':'tree branches',
 'огонь':'fire', 'молния':'lightning', 'дождь':'rain', 'ночь':'a night scene',
 'воздушные_шары':'balloons', 'объёмные_формы':'abstract three dimensional objects',
}
STYLES = {'фотография':'a photograph', '3d_графика':'a 3D rendered illustration',
          'векторная_графика':'a vector illustration', 'рисунок':'a hand drawn illustration', 'фотоколлаж':'a collage of photographs',
          'абстракция':'abstract digital art', 'пиксельная_графика':'pixel art'}

def measured_tags(image, width, height):
    tags = ['обои', 'горизонтальный' if width>height else 'вертикальный' if height>width else 'квадратный']
    ratio=width/height
    for name,value in [('16:9',16/9),('16:10',1.6),('4:3',4/3),('3:2',1.5),('9:16',9/16),('1:1',1)]:
        if abs(ratio-value)<.025: tags.append('формат_'+name.replace(':','_'));break
    if width>=3840 and height>=2160: tags.append('4k_и_выше')
    elif width>=2560 and height>=1440: tags.append('qhd')
    elif width>=1920 and height>=1080: tags.append('full_hd')
    else: tags.append('компактное_разрешение')
    counts={}
    small=image.resize((48,48))
    pixels=small.get_flattened_data() if hasattr(small,'get_flattened_data') else small.getdata()
    for r,g,b in pixels:
        h,s,v=colorsys.rgb_to_hsv(r/255,g/255,b/255)
        if v<.14: key='чёрный'
        elif s<.12: key='белый' if v>.85 else 'серый'
        elif h<.035 or h>=.96:key='красный'
        elif h<.12:key='оранжевый' if v>.55 else 'коричневый'
        elif h<.19:key='жёлтый'
        elif h<.45:key='зелёный'
        elif h<.55:key='бирюзовый'
        elif h<.72:key='синий'
        elif h<.84:key='фиолетовый'
        else:key='розовый'
        counts[key]=counts.get(key,0)+1
    tags += [k for k,v in sorted(counts.items(),key=lambda x:-x[1])[:3] if v/2304>.09]
    return tags

def load_image(path):
    warning = None
    def decode():
        with Image.open(path) as raw:
            try: return ImageOps.exif_transpose(raw).convert('RGB')
            except (SyntaxError, ValueError): return raw.convert('RGB')
    try:
        return decode(), warning
    except OSError as exc:
        if 'image file is truncated' not in str(exc): raise
        previous = ImageFile.LOAD_TRUNCATED_IMAGES
        try:
            ImageFile.LOAD_TRUNCATED_IMAGES = True
            return decode(), 'Original JPEG has an incomplete ending; decoded tolerantly for tagging only.'
        finally:
            ImageFile.LOAD_TRUNCATED_IMAGES = previous

def reviewed_tags(item, reviewed):
    return reviewed.get(item['url']) or (reviewed.get(item['url'].split('/')[-1]) if item['category'] == 'asadal_stock' else None)

def main():
    import torch
    import open_clip
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('--batch',type=int,default=24);a=p.parse_args()
    data=json.loads((a.directory/'downloaded.json').read_text())
    reviewed=json.loads(Path(__file__).with_name('reviewed.json').read_text())
    if any('error' in x for x in data['items']):p.error('Finish downloads first')
    path=a.directory/'tagged.json';done={}
    if path.exists():done={x['sha256']:x for x in json.loads(path.read_text())['items']}
    device='mps' if torch.backends.mps.is_available() else 'cuda' if torch.cuda.is_available() else 'cpu'
    torch.set_num_threads(4)
    model,_,preprocess=open_clip.create_model_and_transforms('ViT-B-32',pretrained='laion2b_s34b_b79k',device=device)
    model.eval();tokenizer=open_clip.get_tokenizer('ViT-B-32')
    vocab={**SUBJECTS,**STYLES};keys=list(vocab)
    with torch.inference_mode():
        text=model.encode_text(tokenizer([f'A wallpaper showing {v}.' for v in vocab.values()]).to(device));text=text/text.norm(dim=-1,keepdim=True)
    results=[]
    for start in range(0,len(data['items']),a.batch):
        batch=data['items'][start:start+a.batch];pending=[x for x in batch if x['sha256'] not in done]
        images=[];pixels=[]
        for item in pending:
            im, warning = load_image(a.directory/item['file'])
            if warning: item['decodingWarning'] = warning
            item['width'],item['height']=im.size
            images.append(preprocess(im));pixels.append(measured_tags(im,item['width'],item['height']))
        if images:
            with torch.inference_mode():
                features=model.encode_image(torch.stack(images).to(device));features=features/features.norm(dim=-1,keepdim=True);scores=(features@text.T).cpu().tolist()
            for item,measured,score in zip(pending,pixels,scores):
                ranked=sorted(zip(keys,score),key=lambda x:-x[1]);subjects=[(k,s) for k,s in ranked if k in SUBJECTS]
                chosen=[k for k,s in subjects[:4] if s>=max(.23,subjects[0][1]-.035)]
                style=next(k for k,s in ranked if k in STYLES)
                manual=reviewed_tags(item, reviewed)
                semantic=manual if manual is not None else chosen+[style]
                tags=sorted(set(measured+semantic+[item['category']]))
                done[item['sha256']]={**item,'tags':tags,'tagging':{'method':'OpenCLIP ViT-B-32 laion2b_s34b_b79k + measured metadata','suggested':chosen+[style], 'reviewed':manual is not None}}
        for x in batch:
            manual=reviewed_tags(x, reviewed)
            if manual is not None:
                old=done[x['sha256']]
                old['tags']=sorted((set(old['tags'])-set(old['tagging']['suggested']))|set(manual))
                old['tagging']['reviewed']=True
                old['tagging']['suggested']=manual
        results += [{**done[x['sha256']], 'url':x['url'],'sourcePage':x['sourcePage'],'file':x['file'],'title':x['title'],'category':x['category']} for x in batch]
        if start%(a.batch*10)==0 or len(results)==len(data['items']):
            write_json(path,{**data,'items':results});print(f'Tagged {len(results)}/{len(data["items"])} on {device}',flush=True)
    print('Tagging complete; semantic tags are suggestions, not manually verified facts.',flush=True)
if __name__=='__main__':main()
