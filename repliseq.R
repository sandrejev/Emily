# setwd("/mnt/e/Workspace/Emily")
# library(randomForest)
library(dplyr)
library(reshape2)
library(readr)
library(GenomicRanges)
library(GenomicFeatures)
library(ggplot2)
library(tidyr)
library(baseline)
library(smoother)
library(dbscan)
library(ggpmisc)
library(rtracklayer)
library(ggbeeswarm)
library(Rtsne)
library(pracma)
devtools::load_all('breaktools')

liftOverRanges = function(ranges, chain) {
  ranges$ranges_id = 1:length(ranges)
  as.data.frame(unlist(rtracklayer::liftOver(ranges, chain))) %>%
    dplyr::group_by(ranges_id) %>%
    dplyr::mutate(start=min(start), end=max(end)) %>%
    dplyr::ungroup() %>%
    dplyr::distinct(ranges_id, .keep_all=T) %>%
    dplyr::select(-ranges_id)
}

repliseq_read = function(path) {
  repliseq_df = as.data.frame(t(readr::read_tsv(path, col_names=F))) %>%
    dplyr::rename(repliseq_chrom="V1", repliseq_start="V2", repliseq_end="V3") %>%
    dplyr::mutate(repliseq_start=as.numeric(repliseq_start), repliseq_end=as.numeric(repliseq_end)) %>%
    reshape2::melt(id.vars=c("repliseq_chrom", "repliseq_start", "repliseq_end"), variable.name="repliseq_fraction", value.name="repliseq_value") %>%
    dplyr::mutate(repliseq_fraction=as.numeric(gsub("V", "", repliseq_fraction))-3, repliseq_value=as.numeric(repliseq_value))
  repliseq_df.keep = repliseq_df %>%
    dplyr::arrange(repliseq_start) %>%
    dplyr::group_by(repliseq_chrom, repliseq_start, repliseq_end) %>%
    dplyr::summarize(repliseq_isna=sum(is.na(repliseq_value))>10) %>%
    dplyr::group_by(repliseq_chrom) %>%
    dplyr::mutate(first_value_position=min(which(!repliseq_isna)), last_value_position=max(which(!repliseq_isna)), keep_value=dplyr::between(1:n(), first_value_position, last_value_position)) %>%
    dplyr::filter(keep_value) %>%
    dplyr::ungroup() %>%
    dplyr::select(repliseq_chrom, repliseq_start, repliseq_end)
  repliseq_df.f = repliseq_df %>%
    dplyr::inner_join(repliseq_df.keep, by=c("repliseq_chrom", "repliseq_start", "repliseq_end"))

  repliseq_df.f
}

repliseq_summarize = function(repliseq_df, window=5) {
  th.repliseq_value_norm = 0.1
  repliseq_df = repliseq_df %>%
    dplyr::group_by(repliseq_chrom, repliseq_start, repliseq_end) %>%
    dplyr::mutate(repliseq_value_norm=((repliseq_value)/max(repliseq_value))) %>%
    dplyr::ungroup() %>%
    dplyr::group_by(repliseq_chrom, repliseq_start, repliseq_end) %>%
    do((function(z) {
      zz<<-z

      i.max = z$repliseq_fraction[which.max(z$repliseq_value_norm)]
      lb = which(z$repliseq_value_norm < th.repliseq_value_norm & z$repliseq_fraction < i.max)
      lb = z$repliseq_fraction[ifelse(length(lb), lb[length(lb)]+1, 1)]
      ub = which(z$repliseq_value_norm < th.repliseq_value_norm & z$repliseq_fraction > i.max)
      ub = z$repliseq_fraction[ifelse(length(ub), ub[1]-1, nrow(z))]

      z$repliseq_value_in_scope = dplyr::between(z$repliseq_fraction, lb, ub)
      z
    })(.)) %>%
    dplyr::ungroup()

  repliseq_time_df = repliseq_df %>%
    dplyr::mutate(repliseqTime_chrom=repliseq_chrom, repliseqTime_start=repliseq_start, repliseqTime_end=repliseq_end) %>%
    dplyr::group_by(repliseqTime_chrom, repliseqTime_start, repliseqTime_end) %>%
    dplyr::mutate(repliseqTime_avg=weighted.mean(repliseq_fraction[repliseq_value_in_scope], repliseq_value_norm[repliseq_value_in_scope], na.rm=T)) %>%
    dplyr::mutate(lb=dplyr::between(repliseq_fraction, floor(repliseqTime_avg[1]-4), ceiling(repliseqTime_avg[1]-2)), repliseqTime_min=ifelse(any(lb), weighted.mean(repliseq_fraction[lb], repliseq_value_norm[lb]), NA_real_)) %>%
    dplyr::mutate(ub=dplyr::between(repliseq_fraction, floor(repliseqTime_avg[1]+2), ceiling(repliseqTime_avg[1]+4)), repliseqTime_max=ifelse(any(ub), weighted.mean(repliseq_fraction[ub], repliseq_value_norm[ub]), NA_real_)) %>%
    dplyr::summarize(repliseqTime_avg=repliseqTime_avg[1], repliseqTime_min=repliseqTime_min[1], repliseqTime_max=repliseqTime_max[1], repliseqTime_lb=min(which(repliseq_value_in_scope)), repliseqTime_ub=max(which(repliseq_value_in_scope))) %>%
    dplyr::group_by(repliseqTime_chrom) %>%
    dplyr::mutate(repliseqTime_avg=smoother::smth.gaussian(repliseqTime_avg, window=window), repliseqTime_min=smoother::smth.gaussian(repliseqTime_min, window=window), repliseqTime_max=smoother::smth.gaussian(repliseqTime_max, window=window)) %>%
    dplyr::mutate(repliseqTime_avg=zoo::na.fill(repliseqTime_avg, "extend"), repliseqTime_min=zoo::na.fill(repliseqTime_min, "extend"), repliseqTime_max=zoo::na.fill(repliseqTime_max, "extend")) %>%
    dplyr::ungroup()

  repliseq_time_df
}

repliseq_preprocess = function() {
  # Load repliseq data
  repliseq_ESC_df = repliseq_read("data/zhao_bmc_repliseq_2020/GSE137764_mESC_Gaussiansmooth_scaled_autosome.mat") %>% dplyr::mutate(repliseq_celltype="esc")
  repliseq_NPC_df = repliseq_read("zdata/zhao_bmc_repliseq_2020/GSE137764_mNPC_Gaussiansmooth_scaled_autosome.mat") %>% dplyr::mutate(repliseq_celltype="npc")
  repliseq_ESC2NPC_df = dplyr::bind_rows(repliseq_ESC_df, repliseq_NPC_df)
  readr::write_tsv(repliseq_ESC2NPC_df,"data/zhao_bmc_repliseq_2020/preprocessed/repliseq.tsv")

  repliseqTime_ESC_df = repliseq_summarize(repliseq_ESC_df) %>% dplyr::mutate(repliseqTime_celltype="esc")
  repliseqTime_NPC_df = repliseq_summarize(repliseq_NPC_df) %>% dplyr::mutate(repliseqTime_celltype="npc")
  repliseqTime_ESC2NPC_df = dplyr::bind_rows(repliseqTime_ESC_df, repliseqTime_NPC_df)
  readr::write_tsv(repliseqTime_ESC2NPC_df,"data/zhao_bmc_repliseq_2020/preprocessed/repliseqTime.tsv")


  repliseq_merged_df = repliseq_ESC2NPC_df %>%
    dplyr::group_by(repliseq_chrom, repliseq_start, repliseq_end, repliseq_fraction) %>%
    dplyr::summarize(repliseq_value=mean(repliseq_value, na.rm=T)) %>%
    dplyr::arrange(repliseq_chrom, repliseq_start, repliseq_end, repliseq_fraction)
  repliseqTime_merged_df = repliseq_summarize(repliseq_merged_df) %>% dplyr::mutate(repliseqTime_celltype="esc/npc")
  readr::write_tsv(repliseqTime_merged_df,"data/zhao_bmc_repliseq_2020/preprocessed/repliseqTime_merged.tsv")
}



main = function() {
  m9_m10 = rtracklayer::import.chain("data/mm9/mm9ToMm10.over.chain")

  # chromosomes_map_df = readr::read_tsv("data/chromosome_synonyms.tsv")

  # Load genome info
  chromsizes_cols = readr::cols(seqnames=col_character(), seqlengths=col_double())
  genome_info = with(readr::read_tsv("data/mm10/annotation/mm10.chrom.sizes", col_names=names(chromsizes_cols$cols), col_types=chromsizes_cols),
           GenomeInfoDb::Seqinfo(seqnames, seqlengths, isCircular=rep(F, length(seqnames)), genome=rep("mm10", length(seqnames))))
  genome_info = genome_info[paste0("chr", c(1:19, "X", "Y"))]

  genome_txdb = GenomicFeatures::makeTxDbFromGFF('data/mm10/annotation/mm10.refGene.gtf.gz', format="gtf")
  genes_df = as.data.frame(GenomicFeatures::genes(genome_txdb)) %>%
    dplyr::mutate(gene_chrom=as.character(seqnames), gene_start=start, gene_end=end, gene_strand=strand, gene_length=gene_end-gene_start)
  genes_ranges = GenomicRanges::makeGRangesFromDataFrame(genes_df, keep.extra.columns=T)

  genes_reduced_ranges = genes_ranges
  strand(genes_reduced_ranges) = "*"
  genes_reduced_ranges = GenomicRanges::reduce(genes_reduced_ranges)
  genes_reduced_ranges$gene_cluster = 1:length(genes_reduced_ranges)
  genes_df = as.data.frame(IRanges::mergeByOverlaps(genes_ranges, genes_reduced_ranges)) %>%
    dplyr::select(-dplyr::matches("_ranges\\.")) %>%
    dplyr::group_by(gene_chrom, gene_cluster) %>%
    dplyr::summarize(gene_cluster_size=n(), gene_dominated_length=max(gene_end-gene_start), gene_id=paste0(gene_id, collapse=","), gene_start=min(gene_start), gene_end=max(gene_end), gene_strand="*", gene_length=gene_end-gene_start) %>%
    dplyr::select(-gene_dominated_length)

  chromsizes_cols = readr::cols(seqnames=col_character(), seqlengths=col_double())
  genome_info_mm9 = with(readr::read_tsv("data/mm9/annotation/mm9.chrom.sizes", col_names=names(chromsizes_cols$cols), col_types=chromsizes_cols),
             GenomeInfoDb::Seqinfo(seqnames, seqlengths, isCircular=rep(F, length(seqnames)), genome=rep("mm9", length(seqnames))))
  genome_info_mm9 = genome_info_mm9[paste0("chr", c(1:19, "X", "Y"))]

  #
  # Read TLX
  #
  repeatmasker_df = repeatmasker_read("data/mm10/annotation/ucsc_repeatmasker.tsv")
  samples_df = readr::read_tsv("data/tlx_samples.tsv")
  tlx_df = tlx_read_many(samples_df)


  baits_df = tlx_identify_baits(tlx_df, breaksite_size=19)
  libsize_df = tlx_df %>%
    dplyr::group_by(tlx_group, tlx_group_i) %>%
    dplyr::summarize(sample_size=sum(!tlx_control), control_size=sum(tlx_control))


  tlx_df = tlx_remove_rand_chromosomes(tlx_df)
  tlx_df = tlx_mark_bait_chromosome(tlx_df)
  tlx_df = tlx_mark_bait_junctions(tlx_df, 1.5e6)
  tlx_df = tlx_mark_repeats(tlx_df, repeatmasker_df)
  tlx_df = tlx_df %>%
    dplyr::filter(!tlx_is_bait_junction) %>%
    dplyr::select(-Seq) %>%
    dplyr::mutate(tlx_id=1:n()) %>%
    dplyr::ungroup()
  tlx_ranges = GenomicRanges::makeGRangesFromDataFrame(tlx_df %>% dplyr::mutate(seqnames=Rname, start=Junction, end=Junction), keep.extra.columns=T, ignore.strand=T)

  #
  # Load repliseq
  #
  repliseq_df = readr::read_tsv("data/zhao_bmc_repliseq_2020/preprocessed/repliseq.tsv") %>% dplyr::filter(repliseq_celltype=="npc")

  repliseqAUC_df = repliseq_df %>%
    dplyr::group_by(repliseq_chrom, repliseq_start, repliseq_end) %>%
    dplyr::summarize(repliseqTime_auc=pracma::trapz(repliseq_fraction,repliseq_value/max(repliseq_value)))
  repliseqTime_df = readr::read_tsv("data/zhao_bmc_repliseq_2020/preprocessed/repliseqTime.tsv") %>% dplyr::filter(repliseqTime_celltype=="npc") %>%
    dplyr::mutate(repliseqTime_id=1:n()) %>%
    dplyr::group_by(repliseqTime_celltype, repliseqTime_chrom) %>%
    dplyr::mutate(repliseqTime_smooth=smoother::smth.gaussian(repliseqTime_avg, window=50))
  repliseqTime_df = repliseqTime_df %>%
    dplyr::inner_join(repliseqAUC_df, by=c("repliseqTime_chrom"="repliseq_chrom", "repliseqTime_start"="repliseq_start", "repliseqTime_end"="repliseq_end"))
  repliseqTime_ranges = GenomicRanges::makeGRangesFromDataFrame(repliseqTime_df %>% dplyr::mutate(seqnames=repliseqTime_chrom, start=repliseqTime_end, end=repliseqTime_end), keep.extra.columns=T)

  #
  # Calculate IZ
  #
  repliseqIZ_df = repliseqTime_df %>%
    dplyr::rename(iz_chrom="repliseqTime_chrom", iz_celltype="repliseqTime_celltype") %>%
    dplyr::group_by(iz_chrom, iz_celltype) %>%
    dplyr::do((function(z){
      zz<<-z
      z.valleys = which(ggpmisc:::find_peaks(17-z$repliseqTime_smooth, ignore_threshold=4/16, span=9, strict=F))
      z.peaks = which(ggpmisc:::find_peaks(z$repliseqTime_smooth, ignore_threshold=4/16, span=9, strict=F))
      data.frame(iz_start=c(z.peaks, z.valleys), iz_type=rep(c("peak", "valley"), c(length(z.peaks), length(z.valleys)))) %>%
        dplyr::mutate(iz_time=z$repliseqTime_smooth[iz_start], iz_start=z$repliseqTime_start[iz_start])
    })(.)) %>%
    dplyr::arrange(iz_celltype, iz_chrom, iz_start) %>%
    dplyr::group_by(iz_chrom, iz_celltype) %>%
    dplyr::mutate(iz_type_group=rep(seq_along(rle(iz_type)$values), rle(iz_type)$lengths)) %>%
    dplyr::ungroup() %>%
    dplyr::group_by(iz_celltype, iz_chrom, iz_type_group) %>%
    dplyr::do((function(z){
      if(nrow(z)==1) return(z)
      zz<<-z

      repliseqTime_df %>%
        dplyr::filter(repliseqTime_celltype==z$iz_celltype[1] & repliseqTime_chrom==z$iz_chrom[1] & dplyr::between(repliseqTime_start, min(z$iz_start), max(z$iz_start))) %>%
        dplyr::arrange(repliseqTime_smooth) %>%
        dplyr::slice(1) %>%
        dplyr::mutate(iz_type=z$iz_type[1], iz_type_group=z$iz_type_group[1]) %>%
        dplyr::select(iz_chrom=repliseqTime_chrom, iz_celltype=repliseqTime_celltype, iz_start=repliseqTime_start, iz_type, iz_time=repliseqTime_smooth, iz_type_group)
    })(.)) %>%
    dplyr::ungroup() %>%
    dplyr::mutate(iz_id=1:n())

  breaks_df = readr::read_tsv("data/breaks_islands.tsv") %>%
    dplyr::select(breaks_chrom=seqnames, breaks_start=start, breaks_end=end) %>%
    dplyr::mutate(breaks_group="Breaksite")

  # Create random regions
  random_breaks_df = breaks_df %>%
    dplyr::inner_join(as.data.frame(genome_info) %>% tibble::rownames_to_column("breaks_chrom"), by="breaks_chrom") %>%
    dplyr::group_by(breaks_chrom, breaks_start, breaks_end) %>%
    dplyr::do((function(z){
      zz<<-z
      n = 100
      z.start = sample(z$seqlengths[1], nrow(z)*n)

      z.length = z$breaks_end-z$breaks_start
      d1 = repliseqIZ_df %>%
        dplyr::sample_n(n()) %>%
        dplyr::group_by(iz_type) %>%
        dplyr::slice(1) %>%
        dplyr::ungroup() %>%
        dplyr::mutate(breaks_chrom=iz_chrom, breaks_start=iz_start-z.length/2, breaks_end=iz_start+z.length/2, breaks_group=paste("Random", iz_type)) %>%
        dplyr::select(breaks_chrom, breaks_start, breaks_end, breaks_group)


      d2 = data.frame(breaks_chrom=z$breaks_chrom[1], seqlengths=z$seqlengths[1], breaks_start=z.start, breaks_length=rep(z$breaks_end-z$breaks_start, each=n)) %>%
        dplyr::mutate(breaks_start=ifelse(breaks_start+breaks_length>=seqlengths, breaks_start-breaks_length, breaks_start), breaks_end=breaks_start+breaks_length, breaks_group="Random positions") %>%
        dplyr::select(breaks_chrom, breaks_start, breaks_end, breaks_group)

      rbind(d1, d2)
    })(.)) %>%
    dplyr::ungroup()

  breaks_all_df = rbind(breaks_df, random_breaks_df) %>%
    tidyr::crossing(data.frame(breaks_range=c(1e5, 2e5, 5e5)))
  breaks_ranges = GenomicRanges::makeGRangesFromDataFrame(breaks_all_df %>% dplyr::mutate(seqnames=breaks_chrom, start=breaks_start-breaks_range, end=breaks_end+breaks_range), keep.extra.columns=T)
  breaks2repliseqTime_df = as.data.frame(IRanges::mergeByOverlaps(breaks_ranges, repliseqTime_ranges)) %>%
    dplyr::group_by(breaks_group, breaks_range, breaks_chrom, breaks_start, breaks_end) %>%
    dplyr::summarize(repliseqTime_auc=max(repliseqTime_auc)/(breaks_end-breaks_start))

  ggplot(breaks2repliseqTime_df) +
    geom_boxplot(aes(y=repliseqTime_auc, x=as.factor(breaks_range/1e3), fill=breaks_group)) +
    theme_gray(base_size=20) +
    labs(x="Size normalized down(up)stream region around breaksite (Kbp)", y="AUC", fill="Source")


  #
  # Plot peaks and valles
  #
# 1           chr1     128914734   128924733
# 2           chr2      98652381    98677237
# 3           chr4     141549783   141570038
# 4           chr6      70860951    70870950
# 5           chr6      70892557    70947374
# 6           chr6      70950836    71008225
# 7           chr6      71014838    71029382
# 8           chr9       3002347     3036749
# 9           chr9      35305232    35315434
# 10         chr14      19406383    19429377
# 11          chrX     169969169   169979168

  chr = "chrX"
  lb = 168e6
  ub = 21e6
  tlxcov_df = tlx_coverage(tlx_df, group="group", extsize=5e5, exttype="symmetrical") %>%
    dplyr::mutate(tlx_separate=as.factor(paste0(tlx_group, " / ", ifelse(tlx_control, "ctrl", "tmnt"))))
  # v = nucleosomes_df %>% dplyr::filter(seqnames==chr & (dplyr::between(start, lb, ub) | dplyr::between(end, lb, ub)))
  w = repliseq_df %>% dplyr::filter(repliseq_chrom==chr & dplyr::between(repliseq_start, lb, ub))
  x = repliseqTime_df %>% dplyr::filter(repliseqTime_chrom==chr & dplyr::between(repliseqTime_start, lb, ub))
  y = repliseqIZ_df %>% dplyr::filter(iz_chrom==chr & dplyr::between(iz_start, lb, ub)) %>% data.frame()
  z = tlxcov_df %>% dplyr::filter(tlxcov_chrom==chr & dplyr::between(tlxcov_start, lb, ub)) %>% data.frame()

  ggplot(x) +
    geom_tile(aes(x=repliseq_start/2+repliseq_end/2, y=repliseq_fraction, fill=repliseq_value), data=w) +
    geom_line(aes(x=repliseqTime_start, y=repliseqTime_avg), color="#FF0000") +
    geom_line(aes(x=repliseqTime_start, y=repliseqTime_smooth), color="#FF0000") +
    geom_line(aes(x=repliseqTime_start, y=repliseqTime_auc), color="#FFCC00") +
    geom_step(aes(x=tlxcov_start, y=-15+as.numeric(tlx_separate)+tlxcov_pileup/5, color=tlx_separate), data=z) +
    # geom_vline(aes(xintercept=iz_start, color=iz_type), data=y) +
    ggtitle(stringr::str_glue("{chr}:{format(start, scientific=F)}-{format(end, scientific=F)}", chr=chr, start=lb/1e6, end=ub/1e6)) +
    coord_cartesian(ylim=c(-15, 16)) +
    labs(x="") +
    scale_color_manual(values=c("peak"="#CCCCCC", "valley"="#CCCCCC",  "APH / tmnt"="#1F78B4", "APH / ctrl"="#A6CEE3", "HU / tmnt"="#33A02C", "HU / ctrl"="#B2DF8A")) +
    scale_fill_gradientn(colours=c("#666666", "#CCCCCC", "#FFFFFF", "#00FFFF", "#000066"), values=c(0, 0.1, 0.3, 0.5, 1)) +
    facet_grid(tlx_group~.) +
    theme_gray(base_size = 21)

  #
  # Correlate breaks density with peaks and surroundings
  #
  repliseqIZtmp_df = repliseqIZ_df %>% dplyr::mutate(iz_lb=iz_start-25e4, iz_ub=iz_start+25e4)
  repliseqIZtmp_ranges = GenomicRanges::makeGRangesFromDataFrame(repliseqIZtmp_df %>% dplyr::select(seqnames=iz_chrom, start=iz_start, end=iz_start))
  repliseqIZsuround_df = repliseqIZtmp_df %>%
    dplyr::mutate(iz_next_id=GenomicRanges::precede(repliseqIZtmp_ranges), iz_prev_id=GenomicRanges::follow(repliseqIZtmp_ranges)) %>%
    dplyr::inner_join(repliseqIZtmp_df %>% setNames(gsub("^iz", "iz_prev", colnames(.))), by="iz_prev_id") %>%
    dplyr::inner_join(repliseqIZtmp_df %>% setNames(gsub("^iz", "iz_next", colnames(.))), by="iz_next_id") %>%
    dplyr::mutate(iz_type_extra=paste(iz_prev_type, iz_type, iz_next_type), iz_time_mindiff=pmin(abs(iz_time-iz_next_time), abs(iz_time-iz_prev_time))) %>%
    dplyr::filter(iz_type_extra %in% c("valley peak valley", "peak valley peak")) %>%
    dplyr::mutate(iz_surround_id=1:n()) %>%
    dplyr::filter(iz_type=="valley" & iz_time<5) %>%
    dplyr::filter(iz_lb-iz_prev_ub>0) %>%
    dplyr::filter(iz_next_lb-iz_ub>0) %>%
    dplyr::filter(iz_time_mindiff>2)
  repliseqIZsuround_ldf = rbind(
    repliseqIZsuround_df %>% dplyr::mutate(iz_surround_pos="early") %>% dplyr::select(iz_surround_id, iz_surround_pos, iz_time_mindiff, dplyr::matches("^iz_"), -dplyr::matches("^iz_(next|prev)"), -iz_type_extra),
    repliseqIZsuround_df %>% dplyr::mutate(iz_surround_pos="left late") %>% dplyr::select(iz_surround_id, iz_surround_pos, iz_time_mindiff, dplyr::matches("^iz_prev")) %>% setNames(gsub("_prev_", "_", colnames(.))),
    repliseqIZsuround_df %>% dplyr::mutate(iz_surround_pos="right late") %>% dplyr::select(iz_surround_id, iz_surround_pos, iz_time_mindiff, dplyr::matches("^iz_next")) %>% setNames(gsub("_next_", "_", colnames(.)))
  )
  repliseqIZsuround_lranges = GenomicRanges::makeGRangesFromDataFrame(repliseqIZsuround_ldf %>% dplyr::mutate(seqnames=iz_chrom, start=iz_lb, end=iz_ub), keep.extra.columns=T)
  repliseqIZsuround2tlx_ldf = as.data.frame(IRanges::mergeByOverlaps(tlx_ranges, repliseqIZsuround_lranges))
  repliseqIZsuround2tlx_ldf = repliseqIZsuround2tlx_ldf %>%
    dplyr::group_by(iz_surround_id, iz_surround_pos, tlx_group, tlx_group_i, tlx_control, tlx_sample) %>%
    dplyr::summarize(breaks_count=n()) %>%
    dplyr::ungroup() %>%
    dplyr::inner_join(libsize_df %>% reshape2::melt(measure.vars=c("sample_size", "control_size"), value.name="library_size") %>% dplyr::mutate(tlx_control=grepl("control", variable)), by=c("tlx_group", "tlx_group_i", "tlx_control")) %>%
    dplyr::mutate(breaks_norm=1e6*breaks_count/library_size) %>%
    dplyr::group_by(iz_surround_id, iz_surround_pos, tlx_group, tlx_control) %>%
    dplyr::summarize(breaks_count=sum(breaks_count), breaks_norm=mean(breaks_norm)) %>%
    dplyr::ungroup()


  ggplot(repliseqIZsuround2tlx_ldf) +
    geom_boxplot(aes(x=iz_surround_pos, fill=tlx_control, y=breaks_norm)) +
    labs(y="Breaks per million") +
    facet_grid(~tlx_group, scales="free_x")
}