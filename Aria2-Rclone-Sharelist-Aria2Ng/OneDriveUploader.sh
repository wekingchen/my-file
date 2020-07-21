#!/bin/bash

GID="$1";
FileNum="$2";
File="$3";
MaxSize="52428800";
Thread="5";  #Ĭ��3�̣߳������޸ģ����������ò��õĻ���������̫��
Block="50";  #Ĭ�Ϸֿ�20m�������޸�
RemoteDIR="upload";  #�ϴ���Onedrive��·����Ĭ��Ϊ��Ŀ¼�����Ҫ�ϴ���MOERATSĿ¼��""���������MOERATS
LocalDIR="/root/Download/";  #Aria2����Ŀ¼���ǵ���������/
Uploader="/usr/local/bin/OneDriveUploader";  #�ϴ��ĳ�������·����Ĭ��Ϊ���İ�װ��Ŀ¼
Config="/root/auth.json";  #��ʼ�����ɵ�����auth.json����·�����ο���3�������ɵ�·��


if [[ -z $(echo "$FileNum" |grep -o '[0-9]*' |head -n1) ]]; then FileNum='0'; fi
if [[ "$FileNum" -le '0' ]]; then exit 0; fi
if [[ "$#" != '3' ]]; then exit 0; fi

function LoadFile(){
  if [[ ! -e "${Uploader}" ]]; then return; fi
  IFS_BAK=$IFS
  IFS=$'\n'
  tmpFile="$(echo "${File/#$LocalDIR}" |cut -f1 -d'/')"
  FileLoad="${LocalDIR}${tmpFile}"
  if [[ ! -e "${FileLoad}" ]]; then return; fi
  ItemSize=$(du -s "${FileLoad}" |cut -f1 |grep -o '[0-9]*' |head -n1)
  if [[ -z "$ItemSize" ]]; then return; fi
  if [[ "$ItemSize" -ge "$MaxSize" ]]; then
    echo -ne "\033[33m${FileLoad} \033[0mtoo large to spik.\n";
    return;
  fi
  ${Uploader} -c "${Config}" -t "${Thread}" -b "${Block}" -skip -s "${FileLoad}" -r "${RemoteDIR}"
  if [[ $? == '0' ]]; then
    rm -rf "${FileLoad}";
  fi
  IFS=$IFS_BAK
}
LoadFile;