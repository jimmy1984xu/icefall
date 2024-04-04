#!/usr/bin/env bash

# fix segmentation fault reported in https://github.com/k2-fsa/icefall/issues/674
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

set -eou pipefail

nj=15
stage=0
stop_stage=100

# Split XL subset to a number of pieces (about 2000)
# This is to avoid OOM during feature extraction.
num_per_split=50

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/GigaSpeech
#      You can find audio, dict, GigaSpeech.json inside it.
#      You can apply for the download credentials by following
#      https://github.com/SpeechColab/GigaSpeech#download
#
#  - $dl_dir/lm
#      This directory contains the language model downloaded from
#        https://huggingface.co/wgb14/gigaspeech_lm
#
#        - 3gram_pruned_1e7.arpa.gz
#        - 4gram.arpa.gz
#        - lexicon.txt
#
#  - $dl_dir/musan
#      This directory contains the following directories downloaded from
#       http://www.openslr.org/17/
#
#     - music
#     - noise
#     - speech
dl_dir=$PWD/download

. shared/parse_options.sh || exit 1

# vocab size for sentence piece models.
# It will generate data/lang_bpe_xxx,
# data/lang_bpe_yyy if the array contains xxx, yyy
vocab_sizes=(
  500
)

# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if [ $stage -le -1 ] && [ $stop_stage -ge -1 ]; then
  log "stage -1: Download LM"
  # We assume that you have installed the git-lfs, if not, you could install it
  # using: `sudo apt-get install git-lfs && git-lfs install`
  [ ! -e $dl_dir/lm ] && mkdir -p $dl_dir/lm
  git clone https://huggingface.co/wgb14/gigaspeech_lm $dl_dir/lm
  gunzip -c $dl_dir/lm/3gram_pruned_1e7.arpa.gz > $dl_dir/lm/3gram_pruned_1e7.arpa
  gunzip -c $dl_dir/lm/4gram.arpa.gz > $dl_dir/lm/4gram.arpa
fi

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download data"

  [ ! -e $dl_dir/GigaSpeech ] && mkdir -p $dl_dir/GigaSpeech

  # If you have pre-downloaded it to /path/to/GigaSpeech,
  # you can create a symlink
  #
  #   ln -sfv /path/to/GigaSpeech $dl_dir/GigaSpeech
  #
  if [ ! -d $dl_dir/GigaSpeech/audio ] && [ ! -f $dl_dir/GigaSpeech.json ]; then
    # Check credentials.
    if [ ! -f $dl_dir/password ]; then
      echo -n "$0: Please apply for the download credentials by following"
      echo -n "https://github.com/SpeechColab/GigaSpeech#download"
      echo " and save it to $dl_dir/password."
      exit 1;
    fi
    PASSWORD=`cat $dl_dir/password 2>/dev/null`
    if [ -z "$PASSWORD" ]; then
      echo "$0: Error, $dl_dir/password is empty."
      exit 1;
    fi
    PASSWORD_MD5=`echo $PASSWORD | md5sum | cut -d ' ' -f 1`
    if [[ $PASSWORD_MD5 != "dfbf0cde1a3ce23749d8d81e492741b8" ]]; then
      echo "$0: Error, invalid $dl_dir/password."
      exit 1;
    fi
    # Download XL, DEV and TEST sets by default.
    lhotse download gigaspeech --subset XL \
      --subset L \
      --subset M \
      --subset S \
      --subset XS \
      --subset DEV \
      --subset TEST \
      --host tsinghua \
      $dl_dir/password $dl_dir/GigaSpeech
  fi

  # If you have pre-downloaded it to /path/to/musan,
  # you can create a symlink
  #
  #   ln -sfv /path/to/musan $dl_dir/
  #
  if [ ! -d $dl_dir/musan ]; then
    lhotse download musan $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare GigaSpeech manifest (may take 15 minutes)"
  # We assume that you have downloaded the GigaSpeech corpus
  # to $dl_dir/GigaSpeech
  mkdir -p data/manifests
  lhotse prepare gigaspeech --subset XL \
    --subset L \
    --subset M \
    --subset S \
    --subset XS \
    --subset DEV \
    --subset TEST \
    -j $nj \
    $dl_dir/GigaSpeech data/manifests
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Prepare musan manifest"
  # We assume that you have downloaded the musan corpus
  # to $dl_dir/musan
  mkdir -p data/manifests
  lhotse prepare musan $dl_dir/musan data/manifests
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "State 3: Preprocess GigaSpeech manifest"
  if [ ! -f data/fbank/.preprocess_complete ]; then
   python3 ./local/preprocess_gigaspeech.py
   touch data/fbank/.preprocess_complete
  fi
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Compute features for L, M, S, XS, DEV and TEST subsets of GigaSpeech."
  python3 ./local/compute_fbank_gigaspeech.py
fi

if [ $stage -le 5 ] && [ $stop_stage -ge 5 ]; then
  log "Stage 5: Split XL subset into pieces (may take 30 minutes)"
  split_dir=data/fbank/XL_split
  if [ ! -f $split_dir/.split_completed ]; then
    lhotse split-lazy ./data/fbank/gigaspeech_cuts_XL_raw.jsonl.gz $split_dir $num_per_split
    touch $split_dir/.split_completed
  fi
fi

if [ $stage -le 6 ] && [ $stop_stage -ge 6 ]; then
  log "Stage 6: Compute features for XL"
  num_splits=$(find data/fbank/XL_split -name "cuts_XL_raw.*.jsonl.gz" | wc -l)
  python3 ./local/compute_fbank_gigaspeech_splits.py \
    --num-workers 20 \
    --batch-duration 600 \
    --num-splits $num_splits
fi

if [ $stage -le 7 ] && [ $stop_stage -ge 7 ]; then
  log "Stage 7: Combine features for XL (may take 3 hours)"
  if [ ! -f data/fbank/cuts_XL.jsonl.gz ]; then
    pieces=$(find data/fbank/XL_split -name "cuts_XL.*.jsonl.gz")
    lhotse combine $pieces data/fbank/cuts_XL.jsonl.gz
  fi
fi

if [ $stage -le 8 ] && [ $stop_stage -ge 8 ]; then
  log "Stage 8: Compute fbank for musan"
  mkdir -p data/fbank
  ./local/compute_fbank_musan.py
fi

if [ $stage -le 9 ] && [ $stop_stage -ge 9 ]; then
  log "Stage 9: Prepare transcript_words.txt and words.txt"
  lang_dir=data/lang_phone
  mkdir -p $lang_dir
  if [ ! -f $lang_dir/transcript_words.txt ]; then
    gunzip -c "data/manifests/gigaspeech_supervisions_XL.jsonl.gz" \
      | jq '.text' \
      | sed 's/"//g' \
      > $lang_dir/transcript_words.txt

    # Delete utterances with garbage meta tags
    garbage_utterance_tags="<SIL> <MUSIC> <NOISE> <OTHER>"
    for tag in $garbage_utterance_tags; do
      sed -i "/${tag}/d" $lang_dir/transcript_words.txt
    done

    # Delete punctuations in utterances
    punctuation_tags="<COMMA> <EXCLAMATIONPOINT> <PERIOD> <QUESTIONMARK>"
    for tag in $punctuation_tags; do
      sed -i "s/${tag}//g" $lang_dir/transcript_words.txt
    done

    # Ensure space only appears once
    sed -i 's/\t/ /g' $lang_dir/transcript_words.txt
    sed -i 's/[ ][ ]*/ /g' $lang_dir/transcript_words.txt
  fi

  cat $lang_dir/transcript_words.txt | sed 's/ /\n/g' \
    | sort -u | sed '/^$/d' > $lang_dir/words.txt
  (echo '!SIL'; echo '<SPOKEN_NOISE>'; echo '<UNK>'; ) |
    cat - $lang_dir/words.txt | sort | uniq | awk '
    BEGIN {
      print "<eps> 0";
    }
    {
      if ($1 == "<s>") {
        print "<s> is in the vocabulary!" | "cat 1>&2"
        exit 1;
      }
      if ($1 == "</s>") {
        print "</s> is in the vocabulary!" | "cat 1>&2"
        exit 1;
      }
      printf("%s %d\n", $1, NR);
    }
    END {
      printf("#0 %d\n", NR+1);
      printf("<s> %d\n", NR+2);
      printf("</s> %d\n", NR+3);
    }' > $lang_dir/words || exit 1;
  mv $lang_dir/words $lang_dir/words.txt
fi

if [ $stage -le 10 ] && [ $stop_stage -ge 10 ]; then
  log "Stage 10: Prepare phone based lang"
  lang_dir=data/lang_phone
  mkdir -p $lang_dir

  (echo '!SIL SIL'; echo '<SPOKEN_NOISE> SPN'; echo '<UNK> SPN'; ) |
    cat - $dl_dir/lm/lexicon.txt |
    sort | uniq > $lang_dir/lexicon.txt

  if [ ! -f $lang_dir/L_disambig.pt ]; then
    ./local/prepare_lang.py --lang-dir $lang_dir
  fi
fi

if [ $stage -le 11 ] && [ $stop_stage -ge 11 ]; then
  log "Stage 11: Prepare BPE based lang"

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}
    mkdir -p $lang_dir
    # We reuse words.txt from phone based lexicon
    # so that the two can share G.pt later.
    cp data/lang_phone/{words.txt,transcript_words.txt} $lang_dir

    if [ ! -f $lang_dir/bpe.model ]; then
      ./local/train_bpe_model.py \
        --lang-dir $lang_dir \
        --vocab-size $vocab_size \
        --transcript $lang_dir/transcript_words.txt
    fi

    if [ ! -f $lang_dir/L_disambig.pt ]; then
      ./local/prepare_lang_bpe.py --lang-dir $lang_dir
    fi
  done
fi

if [ $stage -le 12 ] && [ $stop_stage -ge 12 ]; then
  log "Stage 12: Prepare bigram P"

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}

    if [ ! -f $lang_dir/transcript_tokens.txt ]; then
      ./local/convert_transcript_words_to_tokens.py \
        --lexicon $lang_dir/lexicon.txt \
        --transcript $lang_dir/transcript_words.txt \
        --oov "<UNK>" \
        > $lang_dir/transcript_tokens.txt
    fi

    if [ ! -f $lang_dir/P.arpa ]; then
      ./shared/make_kn_lm.py \
        -ngram-order 2 \
        -text $lang_dir/transcript_tokens.txt \
        -lm $lang_dir/P.arpa
    fi

    if [ ! -f $lang_dir/P.fst.txt ]; then
      python3 -m kaldilm \
        --read-symbol-table="$lang_dir/tokens.txt" \
        --disambig-symbol='#0' \
        --max-order=2 \
        $lang_dir/P.arpa > $lang_dir/P.fst.txt
    fi
  done
fi

if [ $stage -le 13 ] && [ $stop_stage -ge 13 ]; then
  log "Stage 13: Prepare G"
  # We assume you have installed kaldilm, if not, please install
  # it using: pip install kaldilm

  mkdir -p data/lm

  if [ ! -f data/lm/G_3_gram.fst.txt ]; then
    # It is used in building HLG
    python3 -m kaldilm \
      --read-symbol-table="data/lang_phone/words.txt" \
      --disambig-symbol='#0' \
      --max-order=3 \
      $dl_dir/lm/3gram_pruned_1e7.arpa > data/lm/G_3_gram.fst.txt
  fi

  if [ ! -f data/lm/G_4_gram.fst.txt ]; then
    # It is used for LM rescoring
    python3 -m kaldilm \
      --read-symbol-table="data/lang_phone/words.txt" \
      --disambig-symbol='#0' \
      --max-order=4 \
      $dl_dir/lm/4gram.arpa > data/lm/G_4_gram.fst.txt
  fi
fi

if [ $stage -le 14 ] && [ $stop_stage -ge 14 ]; then
  log "Stage 14: Compile HLG"
  ./local/compile_hlg.py --lang-dir data/lang_phone

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}
    ./local/compile_hlg.py --lang-dir $lang_dir
  done
fi
