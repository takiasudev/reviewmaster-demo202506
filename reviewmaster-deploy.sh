#!/bin/bash

# ============================================================
# ReviewMaster CloudFormation ネストテンプレート デプロイ (CloudShell専用)
# ============================================================

set -e  # エラー時に停止

# === デフォルト設定 ===
STACK_NAME="ReviewMaster-Infrastructure"
REGION=""
S3_BASE_PATH=""
PARAMETERS_FILE="nested-parameters.txt"
MAIN_TEMPLATE="00-main-template.yaml"
DEBUG_MODE=false
SKIP_CONFIRMATION=false

# === ログ出力関数 ===
log_info() {
    echo "[$(date +'%H:%M:%S')] $1"
}

log_success() {
    echo "[$(date +'%H:%M:%S')] $1"
}

log_warning() {
    echo "[$(date +'%H:%M:%S')] 警告: $1"
}

log_error() {
    echo "[$(date +'%H:%M:%S')] エラー: $1"
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[$(date +'%H:%M:%S')] デバッグ: $1"
    fi
}

# === ヘルプ表示 ===
show_help() {
    cat << EOF
ReviewMaster CloudFormation ネストテンプレート デプロイスクリプト (CloudShell専用)

使用方法: $0 -p <S3_BASE_PATH> -r <REGION> [オプション]

必須パラメータ:
  -p, --s3-path PATH          S3資材配置パス (例: s3://my-bucket/reviewmaster)
  -r, --region REGION         AWSリージョン (例: ap-northeast-1)

オプション:
  -s, --stack-name NAME       CloudFormationスタック名 (デフォルト: $STACK_NAME)
  -d, --debug                 デバッグモード（詳細な実行ログを表示）
  -y, --yes                   確認プロンプトをスキップして自動実行
  -h, --help                  ヘルプ表示

前提条件:
  1. 以下のファイルが指定したS3パスに配置済みであること:
     - templates/00-main-template.yaml
     - templates/01-s3.yaml
     - templates/02-dynamo.yaml
     - templates/03-iam.yaml
     - templates/04-lambda.yaml
     - templates/05-api-gateway.yaml
     - templates/06-cloudfront.yaml
     - templates/api-resource/*.yaml (15個)
     - nested-parameters.txt
     - dist/ (フロントエンド資材)
     - lambda/ (バックエンド資材)

例:
  # 基本実行
  $0 -p s3://my-bucket/reviewmaster -r ap-northeast-1

  # デバッグモード実行（問題のトラブルシューティング用）
  $0 -p s3://my-bucket/reviewmaster -r ap-northeast-1 --debug

  # 確認プロンプトなしで自動実行
  $0 -p s3://my-bucket/reviewmaster -r ap-northeast-1 --yes

  # カスタムスタック名
  $0 -p s3://my-bucket/reviewmaster -r ap-northeast-1 --stack-name "MyCompany-reviewmaster"

S3資材配置例:
  s3://my-bucket/reviewmaster/
  ├── templates/
  │   ├── 00-main-template.yaml
  │   ├── 01-s3.yaml
  │   ├── 02-dynamo.yaml
  │   ├── 03-iam.yaml
  │   ├── 04-lambda.yaml
  │   ├── 05-api-gateway.yaml
  │   ├── 06-cloudfront.yaml
  │   └── api-resource/
  │       ├── 05-01-api-upload.yaml
  │       ├── 05-02-api-manage.yaml
  │       ├── ...
  │       └── 05-15-api-file-download.yaml
  ├── nested-parameters.txt
  ├── dist/ (フロントエンド資材)
  └── lambda/ (バックエンド資材)
      ├── config_manager.zip
      ├── file_storage.zip
      ├── rag_search.zip
      ├── result_checker.zip
      ├── review_request.zip
      └── revision_checker.zip

デプロイステップ:
  1. インフラストラクチャデプロイ（暫定CORS設定）
  2. CORS設定更新（実際のCloudFrontドメイン使用）
  2-2. フロントエンド設定ファイル更新（API Gateway URL）
  2-3. API Gateway デプロイメント（prodステージ）
  3. フロントエンド・バックエンドデプロイ

EOF
}

# === パラメータ解析 ===
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--s3-path)
            S3_BASE_PATH="$2"
            shift 2
            ;;
        -s|--stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG_MODE=true
            set +e  # デバッグモードではエラー時停止を無効化
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRMATION=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "不明なオプション: $1"
            show_help
            exit 1
            ;;
    esac
done

# === 必須パラメータチェック ===
if [ -z "$S3_BASE_PATH" ]; then
    log_error "S3ベースパスが指定されていませｄん。-p オプションで指定してください。"
    show_help
    exit 1
fi

if [ -z "$REGION" ]; then
    log_error "AWSリージョンが指定されていません。-r オプションで指定してください。"
    show_help
    exit 1
fi

# S3パスの正規化（末尾スラッシュ除去）
S3_BASE_PATH=${S3_BASE_PATH%/}

# === 実行確認 ===
confirm_execution() {
    echo ""
    echo "============================================================"
    echo " デプロイ実行確認"
    echo "============================================================"
    echo ""
    echo "以下の設定でデプロイを実行します："
    echo "  スタック名: $STACK_NAME"
    echo "  リージョン: $REGION"
    echo "  S3ベースパス: $S3_BASE_PATH"
    echo ""
    echo "デプロイステップ:"
    echo "  1. インフラストラクチャデプロイ（暫定CORS設定）"
    echo "  2. CORS設定更新（実際のCloudFrontドメイン使用）"
    echo "  2-2. フロントエンド設定ファイル更新（API Gateway URL）"
    echo "  2-3. API Gateway デプロイメント（prodステージ）"
    echo "  3. フロントエンド・バックエンドデプロイ"
    echo ""
    
    if [ "$SKIP_CONFIRMATION" = true ]; then
        log_info "確認プロンプトをスキップしてデプロイを開始します..."
        return 0
    fi
    
    echo "処理を続行しますか？ (y/N)"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY])
            log_info "デプロイを開始します..."
            ;;
        *)
            log_info "デプロイをキャンセルしました。"
            exit 0
            ;;
    esac
}

# === 前提条件チェック ===
check_prerequisites() {
    log_info "前提条件をチェック中..."
    
    # AWS CLI チェック
    log_info "AWS CLIの存在確認中..."
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLIがインストールされていません"
        exit 1
    fi
    log_info "AWS CLI確認完了"
    
    # AWS認証チェック
    log_info "AWS認証の確認中..."
    if ! aws sts get-caller-identity 2>&1; then
        log_error "AWS認証が設定されていません"
        log_error "CloudShellでAWS認証に問題があります"
        exit 1
    fi
    log_info "AWS認証確認完了"
    
    # リージョン設定確認
    log_info "使用リージョン: $REGION"
    
    log_success "前提条件チェック完了"
}

# === S3資材存在確認 ===
check_s3_resources() {
    log_info "S3資材の存在確認中..."
    
    # パラメータファイル確認
    if ! aws s3 ls "$S3_BASE_PATH/$PARAMETERS_FILE" &> /dev/null; then
        log_error "パラメータファイルが見つかりません: $S3_BASE_PATH/$PARAMETERS_FILE"
        exit 1
    fi
    
    # メインテンプレート確認
    if ! aws s3 ls "$S3_BASE_PATH/templates/$MAIN_TEMPLATE" &> /dev/null; then
        log_error "メインテンプレートが見つかりません: $S3_BASE_PATH/templates/$MAIN_TEMPLATE"
        exit 1
    fi
    
    # コアテンプレート確認
    local core_templates=(
        "01-s3.yaml"
        "02-dynamo.yaml"
        "03-iam.yaml"
        "04-lambda.yaml"
        "05-api-gateway.yaml"
        "06-cloudfront.yaml"
        "07-eventbridge.yaml"
    )
    
    for template in "${core_templates[@]}"; do
        if ! aws s3 ls "$S3_BASE_PATH/templates/$template" &> /dev/null; then
            log_error "コアテンプレートが見つかりません: $S3_BASE_PATH/templates/$template"
            exit 1
        fi
    done
    
    # APIリソーステンプレート確認
    local api_templates=(
        "05-01-api-upload.yaml"
        "05-02-api-manage.yaml"
        "05-03-api-reviews.yaml"
        "05-04-api-review-point-add.yaml"
        "05-05-api-review-point-update.yaml"
        "05-06-api-review-delete.yaml"
        "05-07-api-result.yaml"
        "05-08-api-status.yaml"
        "05-09-api-download.yaml"
        "05-10-api-project-overview.yaml"
        "05-11-api-review-history.yaml"
        "05-12-api-revision-upload.yaml"
        "05-13-api-revision-status.yaml"
        "05-14-api-revision-result.yaml"
        "05-15-api-file-download.yaml"
    )
    
    for template in "${api_templates[@]}"; do
        if ! aws s3 ls "$S3_BASE_PATH/templates/api-resource/$template" &> /dev/null; then
            log_error "APIリソーステンプレートが見つかりません: $S3_BASE_PATH/templates/api-resource/$template"
            exit 1
        fi
    done
    
    # フロントエンド資材確認
    if ! aws s3 ls "$S3_BASE_PATH/dist/" &> /dev/null; then
        log_warning "フロントエンド資材が見つかりません: $S3_BASE_PATH/dist/"
        log_warning "フロントエンドデプロイはスキップされます"
    fi
    
    # バックエンド資材確認
    local lambda_files=(
        "config_manager.zip"
        "file_storage.zip"
        "rag_search.zip"
        "result_checker.zip"
        "review_request.zip"
        "revision_checker.zip"
    )
    
    local missing_lambda_files=()
    for lambda_file in "${lambda_files[@]}"; do
        if ! aws s3 ls "$S3_BASE_PATH/lambda/$lambda_file" &> /dev/null; then
            missing_lambda_files+=("$lambda_file")
        fi
    done
    
    if [ ${#missing_lambda_files[@]} -gt 0 ]; then
        log_warning "以下のLambda資材が見つかりません:"
        for file in "${missing_lambda_files[@]}"; do
            log_warning "  - $S3_BASE_PATH/lambda/$file"
        done
        log_warning "該当するLambda関数のデプロイはスキップされます"
    fi
    
    log_success "S3資材の存在確認完了（22個のテンプレートファイル確認済み）"
}

# === パラメータファイルダウンロード ===
download_parameters() {
    log_info "パラメータファイルをダウンロード中..."
    
    # 一時ファイルとしてダウンロード
    local temp_params="/tmp/nested-parameters-$(date +%s).txt"
    
    if ! aws s3 cp "$S3_BASE_PATH/$PARAMETERS_FILE" "$temp_params" --region "$REGION"; then
        log_error "パラメータファイルのダウンロードに失敗しました"
        exit 1
    fi
    
    # グローバル変数に設定
    DOWNLOADED_PARAMETERS_FILE="$temp_params"
    
    log_success "パラメータファイルダウンロード完了: $temp_params"
}

# === パラメータをCloudFormation形式に変換 ===
convert_to_cf_parameters() {
    local input_params="$1"
    local cf_params=""
    
    # スペース区切りのパラメータを配列に変換
    local param_array=()
    
    # パラメータを1つずつ解析
    local current_param=""
    local in_quotes=false
    local i=0
    
    while [ $i -lt ${#input_params} ]; do
        local char="${input_params:$i:1}"
        
        if [ "$char" = '"' ]; then
            in_quotes=$([ "$in_quotes" = true ] && echo false || echo true)
            current_param="${current_param}${char}"
        elif [ "$char" = ' ' ] && [ "$in_quotes" = false ]; then
            if [ -n "$current_param" ]; then
                param_array+=("$current_param")
                current_param=""
            fi
        else
            current_param="${current_param}${char}"
        fi
        ((i++))
    done
    
    # 最後のパラメータを追加
    if [ -n "$current_param" ]; then
        param_array+=("$current_param")
    fi
    
    # CloudFormation形式に変換
    for param in "${param_array[@]}"; do
        if [[ "$param" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # ダブルクォーテーションを除去
            if [[ "$value" =~ ^\"(.*)\"$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            
            # CloudFormation形式に追加
            if [ -n "$cf_params" ]; then
                cf_params="${cf_params} "
            fi
            cf_params="${cf_params}ParameterKey=${key},ParameterValue=${value}"
        fi
    done
    
    echo "$cf_params"
}

# === パラメータ読み込み関数 ===
load_parameters() {
    local params=""
    
    # ダウンロードしたパラメータファイルを1行ずつ処理
    while IFS= read -r line || [ -n "$line" ]; do
        # 行の前後の空白を削除
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 空行とコメント行をスキップ
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # Key=Value 形式の解析
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            
            # キーの前後の空白を削除
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # 値の前後の空白を削除
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # ダブルクォーテーションで囲まれている場合は除去
            if [[ "$value" =~ ^\"(.*)\"$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            
            # Key=Value形式で追加（値にスペースが含まれる場合はダブルクォーテーション付き）
            if [ -n "$params" ]; then
                params="$params "
            fi
            
            # 値にスペースが含まれている場合またはコンマが含まれている場合はダブルクォーテーションで囲む
            if [[ "$value" =~ [[:space:],] ]]; then
                params="${params}${key}=\"${value}\""
            else
                params="${params}${key}=${value}"
            fi
        fi
    done < "$DOWNLOADED_PARAMETERS_FILE"
    
    if [ -z "$params" ]; then
        return 1
    fi
    
    echo "$params"
}

# === S3 URLをHTTPS URLに変換 ===
convert_s3_to_https_url() {
    local s3_url="$1"
    
    # s3://bucket-name/path を https://s3.amazonaws.com/bucket-name/path に変換
    if [[ "$s3_url" =~ ^s3://([^/]+)/(.*)$ ]]; then
        local bucket_name="${BASH_REMATCH[1]}"
        local object_key="${BASH_REMATCH[2]}"
        
        # パス形式のHTTPS URLを使用（バケット名に制約がある場合に対応）
        echo "https://s3.amazonaws.com/$bucket_name/$object_key"
    else
        log_error "無効なS3 URL形式: $s3_url"
        exit 1
    fi
}

# === テンプレート構文チェック ===
validate_template() {
    log_info "メインテンプレート構文をチェック中..."
    
    local s3_template_url="$S3_BASE_PATH/templates/$MAIN_TEMPLATE"
    local https_template_url=$(convert_s3_to_https_url "$s3_template_url")
    
    log_debug "S3 URL: $s3_template_url"
    log_debug "HTTPS URL: $https_template_url"
    
    if ! aws cloudformation validate-template \
        --template-url "$https_template_url" \
        --region "$REGION" > /dev/null; then
        log_error "メインテンプレート構文エラーが検出されました"
        exit 1
    fi
    
    log_success "メインテンプレート構文チェック完了"
}

# === CloudFrontドメイン取得 ===
get_cloudfront_domain() {
    local cloudfront_domain=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionDomainName`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -n "$cloudfront_domain" ] && [ "$cloudfront_domain" != "None" ]; then
        echo "$cloudfront_domain"
        return 0
    else
        return 1
    fi
}

# === 二段階デプロイ ===
deploy_two_stage() {
    local parameters="$1"
    
    # TemplateBaseUrlパラメータを設定（HTTPS形式）
    local s3_template_base_url="$S3_BASE_PATH/templates"
    local https_template_base_url=$(convert_s3_to_https_url "$s3_template_base_url/dummy" | sed 's|/dummy$||')
    
    log_debug "Template Base URL (S3): $s3_template_base_url"
    log_debug "Template Base URL (HTTPS): $https_template_base_url"
    
    # TemplateBaseUrlパラメータを追加または更新
    if echo "$parameters" | grep -q "TemplateBaseUrl="; then
        # 既存のTemplateBaseUrlパラメータを置換
        parameters=$(echo "$parameters" | sed "s|TemplateBaseUrl=[^[:space:]]*|TemplateBaseUrl=$https_template_base_url|")
    else
        # TemplateBaseUrlパラメータを追加
        parameters="$parameters TemplateBaseUrl=$https_template_base_url"
    fi
    
    # 既存スタックの存在確認
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" > /dev/null 2>&1; then
        echo ""
        echo "============================================================"
        echo " Phase 1: インフラストラクチャデプロイ（スキップ - 既存スタック）"
        echo "============================================================"
        echo ""
        
        log_info "既存スタックを検出しました。Phase 1をスキップしてCORS設定を更新します..."
        
        # CloudFrontドメイン取得
        log_info "CloudFrontドメインを取得中..."
        local cloudfront_domain=$(get_cloudfront_domain)
        if [ $? -ne 0 ] || [ -z "$cloudfront_domain" ]; then
            log_error "CloudFrontドメインの取得に失敗しました"
            exit 1
        fi
        
        log_success "CloudFrontドメイン取得完了: $cloudfront_domain"
        
        echo ""
        echo "============================================================"
        echo " Phase 2: CORS設定更新（実際のCloudFrontドメイン使用）"
        echo "============================================================"
        echo ""
        
        # CloudFrontDomainパラメータを更新
        local updated_parameters
        if echo "$parameters" | grep -q "CloudFrontDomain="; then
            # 既存のCloudFrontDomainパラメータを置換
            updated_parameters=$(echo "$parameters" | sed "s|CloudFrontDomain=[^[:space:]]*|CloudFrontDomain=$cloudfront_domain|")
        else
            # CloudFrontDomainパラメータを追加
            updated_parameters="$parameters CloudFrontDomain=$cloudfront_domain"
        fi
        
        log_info "CloudFrontドメインを使用してCORS設定とLambda環境変数を更新中..."
        log_info "更新パラメータ:"
        echo "$updated_parameters" | tr ' ' '\n' | sed 's/^/  /'
        deploy_stack_phase2 "$updated_parameters"
        
        log_success "CORS設定更新完了"
        
        # Phase 2-2: フロントエンド設定ファイル更新
        update_frontend_config
        
        # Phase 2-3: API Gateway デプロイメント
        deploy_api_gateway
        
        return 0
    fi
    
    echo ""
    echo "============================================================"
    echo " Phase 1: インフラストラクチャデプロイ（暫定CORS設定）"
    echo "============================================================"
    echo ""
    
    # Phase 1: 初回デプロイ
    deploy_stack_phase1 "$parameters"
    
    # CloudFrontドメイン取得
    log_info "CloudFrontドメインを取得中..."
    local cloudfront_domain=$(get_cloudfront_domain)
    if [ $? -ne 0 ] || [ -z "$cloudfront_domain" ]; then
        log_error "CloudFrontドメインの取得に失敗しました"
        exit 1
    fi
    
    log_success "CloudFrontドメイン取得完了: $cloudfront_domain"
    
    echo ""
    echo "============================================================"
    echo " Phase 2: CORS設定更新（実際のCloudFrontドメイン使用）"
    echo "============================================================"
    echo ""
    
    # Phase 2: CloudFrontDomainパラメータを更新
    local updated_parameters
    if echo "$parameters" | grep -q "CloudFrontDomain="; then
        # 既存のCloudFrontDomainパラメータを置換
        updated_parameters=$(echo "$parameters" | sed "s|CloudFrontDomain=[^[:space:]]*|CloudFrontDomain=$cloudfront_domain|")
    else
        # CloudFrontDomainパラメータを追加
        updated_parameters="$parameters CloudFrontDomain=$cloudfront_domain"
    fi
    
    log_info "CloudFrontドメインを使用してCORS設定とLambda環境変数を更新中..."
    log_info "更新パラメータ:"
    echo "$updated_parameters" | tr ' ' '\n' | sed 's/^/  /'
    deploy_stack_phase2 "$updated_parameters"
    
    log_success "CORS設定更新完了"
    
    # Phase 2-2: フロントエンド設定ファイル更新
    update_frontend_config
    
    # Phase 2-3: API Gateway デプロイメント
    deploy_api_gateway
    
    log_success "二段階デプロイ完了"
}

# === CloudFormation デプロイ (Phase 1) ===
deploy_stack_phase1() {
    local parameters="$1"
    
    log_info "CloudFormationスタックをデプロイ中（Phase 1）..."
    log_info "スタック名: $STACK_NAME"
    log_info "リージョン: $REGION"
    log_info "S3ベースパス: $S3_BASE_PATH"
    
    # 実際のデプロイ実行
    local s3_template_url="$S3_BASE_PATH/templates/$MAIN_TEMPLATE"
    local https_template_url=$(convert_s3_to_https_url "$s3_template_url")
    
    local cf_parameters=$(convert_to_cf_parameters "$parameters")
    log_debug "CloudFormation Parameters: $cf_parameters"
    
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-url "$https_template_url" \
        --parameters $cf_parameters \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --region "$REGION"
    
    # スタック作成完了まで待機
    log_info "スタック作成完了を待機中..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    if [ $? -eq 0 ]; then
        log_success "CloudFormationデプロイ（Phase 1）完了"
    else
        log_error "CloudFormationデプロイ（Phase 1）に失敗しました"
        exit 1
    fi
}

# === CloudFormation デプロイ (Phase 2) ===
deploy_stack_phase2() {
    local parameters="$1"
    
    log_info "CloudFormationスタックを更新中（Phase 2）..."
    
    local s3_template_url="$S3_BASE_PATH/templates/$MAIN_TEMPLATE"
    local https_template_url=$(convert_s3_to_https_url "$s3_template_url")
    
    # スタック更新実行
    local cf_parameters=$(convert_to_cf_parameters "$parameters")
    log_debug "CloudFormation Parameters: $cf_parameters"
    
    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-url "$https_template_url" \
        --parameters $cf_parameters \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --region "$REGION" || {
            # 変更がない場合のエラーをハンドリング
            local exit_code=$?
            if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
                log_info "変更がないため、スタックの更新をスキップしました"
                return 0
            else
                log_error "CloudFormationスタック更新に失敗しました"
                exit $exit_code
            fi
        }
    
    # スタック更新完了まで待機
    log_info "スタック更新完了を待機中..."
    aws cloudformation wait stack-update-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    if [ $? -eq 0 ]; then
        log_success "CloudFormationデプロイ（Phase 2）完了"
    else
        log_error "CloudFormationデプロイ（Phase 2）に失敗しました"
        exit 1
    fi
}

# === フロントエンドS3バケット名取得 ===
get_frontend_bucket() {
    local frontend_bucket=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`FrontendBucketName`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -n "$frontend_bucket" ] && [ "$frontend_bucket" != "None" ]; then
        echo "$frontend_bucket"
        return 0
    else
        return 1
    fi
}

# === API Gateway URL取得 ===
get_api_gateway_url() {
    local api_url=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayUrl`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -n "$api_url" ] && [ "$api_url" != "None" ]; then
        echo "$api_url"
        return 0
    else
        return 1
    fi
}

# === API Gateway REST API ID取得 ===
get_api_gateway_id() {
    local api_id=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`RestApiId`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -n "$api_id" ] && [ "$api_id" != "None" ]; then
        echo "$api_id"
        return 0
    else
        return 1
    fi
}

# === API Gateway デプロイメント ===
deploy_api_gateway() {
    echo ""
    echo "============================================================"
    echo " Phase 2-3: API Gateway デプロイメント"
    echo "============================================================"
    echo ""
    
    # API Gateway REST API ID取得
    log_info "API Gateway REST API IDを取得中..."
    local api_id=$(get_api_gateway_id)
    if [ $? -ne 0 ] || [ -z "$api_id" ]; then
        log_error "API Gateway REST API IDの取得に失敗しました"
        log_error "CloudFormationの出力でRestApiIdが定義されているか確認してください"
        return 1
    fi
    
    log_success "API Gateway REST API ID取得完了: $api_id"
    
    # デプロイメント作成
    log_info "API Gateway デプロイメントを作成中（ステージ: prod）..."
    local deployment_id=$(aws apigateway create-deployment \
        --rest-api-id "$api_id" \
        --stage-name "prod" \
        --description "Automated deployment from CloudShell script $(date +'%Y-%m-%d %H:%M:%S')" \
        --region "$REGION" \
        --query 'id' \
        --output text 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$deployment_id" ] && [ "$deployment_id" != "None" ]; then
        log_success "API Gateway デプロイメント完了"
        log_info "デプロイメントID: $deployment_id"
        log_info "API エンドポイント: https://$api_id.execute-api.$REGION.amazonaws.com/prod"
        
        # デバッグモードの場合、詳細情報を表示
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "デプロイメント詳細:"
            aws apigateway get-deployment \
                --rest-api-id "$api_id" \
                --deployment-id "$deployment_id" \
                --region "$REGION" \
                --output table 2>/dev/null | sed 's/^/  /'
        fi
    else
        log_error "API Gateway デプロイメントに失敗しました"
        log_error "API ID: $api_id"
        
        # デバッグ情報を表示
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "API Gateway ステージ一覧:"
            aws apigateway get-stages \
                --rest-api-id "$api_id" \
                --region "$REGION" \
                --output table 2>/dev/null | sed 's/^/  /'
        fi
        
        return 1
    fi
    
    log_success "API Gateway デプロイメント処理完了"
}

# === config.js更新 ===
update_frontend_config() {
    echo ""
    echo "============================================================"
    echo " Phase 2-2: フロントエンド設定ファイル更新"
    echo "============================================================"
    echo ""
    
    # API Gateway URL取得
    log_info "API Gateway URLを取得中..."
    local api_url=$(get_api_gateway_url)
    if [ $? -ne 0 ] || [ -z "$api_url" ]; then
        log_error "API Gateway URLの取得に失敗しました"
        log_error "CloudFormationの出力でApiGatewayUrlが定義されているか確認してください"
        return 1
    fi
    
    log_success "API Gateway URL取得完了: $api_url"
    
    # config.jsファイルの存在確認
    if ! aws s3 ls "$S3_BASE_PATH/dist/config.js" &> /dev/null; then
        log_warning "config.jsファイルが見つかりません: $S3_BASE_PATH/dist/config.js"
        log_warning "フロントエンド設定ファイル更新をスキップします"
        return 0
    fi
    
    # 一時ディレクトリ作成
    local temp_dir="/tmp/frontend_config_$$"
    mkdir -p "$temp_dir"
    
    # config.jsファイルをダウンロード
    log_info "config.jsファイルをダウンロード中..."
    if ! aws s3 cp "$S3_BASE_PATH/dist/config.js" "$temp_dir/config.js" --region "$REGION"; then
        log_error "config.jsファイルのダウンロードに失敗しました"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # APIエンドポイントURLを更新
    log_info "config.jsファイルのAPIエンドポイントURLを更新中..."
    log_info "新しいAPI Gateway URL: $api_url"
    
    # sedコマンドでAPI_BASE_URLを更新
    sed -i "s|API_BASE_URL: '[^']*'|API_BASE_URL: '$api_url'|g" "$temp_dir/config.js"
    
    if [ $? -eq 0 ]; then
        log_info "config.jsファイル更新完了"
        
        # デバッグモードの場合、更新後のファイル内容を表示
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "更新後のconfig.js内容:"
            cat "$temp_dir/config.js" | sed 's/^/  /'
        fi
        
        # 更新されたconfig.jsファイルをS3にアップロード
        log_info "更新されたconfig.jsファイルをS3にアップロード中..."
        if aws s3 cp "$temp_dir/config.js" "$S3_BASE_PATH/dist/config.js" --region "$REGION"; then
            log_success "config.jsファイルのS3アップロード完了"
        else
            log_error "config.jsファイルのS3アップロードに失敗しました"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        log_error "config.jsファイルの更新に失敗しました"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 一時ディレクトリをクリーンアップ
    rm -rf "$temp_dir"
    
    log_success "フロントエンド設定ファイル更新完了"
}

# === CloudFront Distribution ID取得 ===
get_cloudfront_distribution_id() {
    # ドメイン名から取得（実証済みの確実な方法）
    local cloudfront_domain=$(get_cloudfront_domain)
    if [ $? -eq 0 ] && [ -n "$cloudfront_domain" ]; then
        if [ "$DEBUG_MODE" = true ]; then
            echo "[DEBUG] CloudFrontドメイン: $cloudfront_domain" >&2
        fi
        
        local cloudfront_id=$(aws cloudfront list-distributions \
            --query "DistributionList.Items[?DomainName=='$cloudfront_domain'].Id" \
            --output text 2>/dev/null)
        
        if [ -n "$cloudfront_id" ] && [ "$cloudfront_id" != "None" ]; then
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] ドメイン名からDistribution ID取得成功: $cloudfront_id" >&2
            fi
            echo "$cloudfront_id"
            return 0
        fi
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] Distribution ID取得に失敗しました" >&2
    fi
    return 1
}

# === Lambda関数名取得 ===
get_lambda_function_names() {
    # 一時ファイルを使用してログ出力の混入を完全に防ぐ
    local temp_file="/tmp/lambda_functions_$$"
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] LambdaStackを検索中..." >&2
    fi
    
    # ネストされたLambdaStackの名前を取得
    local lambda_stack_arn=$(aws cloudformation list-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'StackResourceSummaries[?LogicalResourceId==`LambdaStack`].PhysicalResourceId' \
        --output text 2>/dev/null)
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] LambdaStack ARN: $lambda_stack_arn" >&2
    fi
    
    if [ -z "$lambda_stack_arn" ] || [ "$lambda_stack_arn" = "None" ]; then
        if [ "$DEBUG_MODE" = true ]; then
            echo "[DEBUG] LambdaStackが見つかりませんでした" >&2
        fi
        return 1
    fi
    
    # ARNからスタック名を抽出
    # arn:aws:cloudformation:region:account:stack/stack-name/stack-id
    # から stack-name 部分を抽出
    local lambda_stack_name=""
    
    if [[ "$lambda_stack_arn" =~ stack/([^/]+)/ ]]; then
        lambda_stack_name="${BASH_REMATCH[1]}"
        if [ "$DEBUG_MODE" = true ]; then
            echo "[DEBUG] スタック名抽出成功: $lambda_stack_name" >&2
        fi
    else
        if [ "$DEBUG_MODE" = true ]; then
            echo "[DEBUG] スタック名抽出失敗。ARN: $lambda_stack_arn" >&2
        fi
        return 1
    fi
    
    # LambdaStack内のLambda関数を取得
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] スタック '$lambda_stack_name' からLambda関数を取得中..." >&2
    fi
    
    aws cloudformation describe-stack-resources \
        --stack-name "$lambda_stack_name" \
        --region "$REGION" \
        --query 'StackResources[?ResourceType==`AWS::Lambda::Function`].[LogicalResourceId,PhysicalResourceId]' \
        --output text > "$temp_file" 2>/dev/null
    
    local aws_exit_code=$?
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] AWS CLI終了コード: $aws_exit_code" >&2
        echo "[DEBUG] 一時ファイルサイズ: $([ -f "$temp_file" ] && wc -l < "$temp_file" || echo "ファイルなし") 行" >&2
        if [ -f "$temp_file" ]; then
            echo "[DEBUG] 一時ファイル内容:" >&2
            cat "$temp_file" >&2
        fi
    fi
    
    if [ ! -s "$temp_file" ]; then
        if [ "$DEBUG_MODE" = true ]; then
            echo "[DEBUG] LambdaStack内にLambda関数が見つかりませんでした" >&2
            echo "[DEBUG] 手動確認用コマンド:" >&2
            echo "[DEBUG] aws cloudformation describe-stack-resources --stack-name '$lambda_stack_name' --region '$REGION' --query 'StackResources[?ResourceType==\`AWS::Lambda::Function\`]' --output table" >&2
        fi
        rm -f "$temp_file"
        return 1
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] 検出されたLambda関数:" >&2
        cat "$temp_file" >&2
    fi
    
    # Lambda関数名をマッピング
    declare -A lambda_functions
    
    while IFS=$'\t' read -r logical_id physical_id; do
        # 空行をスキップ
        if [ -z "$logical_id" ] || [ -z "$physical_id" ]; then
            continue
        fi
        
        if [ "$DEBUG_MODE" = true ]; then
            echo "[DEBUG] チェック中: LogicalId='$logical_id', PhysicalId='$physical_id'" >&2
        fi
        
        # 大文字小文字を区別せずに部分一致チェック
        logical_id_lower=$(echo "$logical_id" | tr '[:upper:]' '[:lower:]')
        
        # 実際のLogicalResourceIdパターンに基づいてマッチング
        if [[ "$logical_id_lower" =~ configmanager|config.*manager ]]; then
            lambda_functions["config_manager"]="$physical_id"
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] マッチ: config_manager -> $physical_id" >&2
            fi
        elif [[ "$logical_id_lower" =~ filestorage|file.*storage ]]; then
            lambda_functions["file_storage"]="$physical_id"
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] マッチ: file_storage -> $physical_id" >&2
            fi
        elif [[ "$logical_id_lower" =~ ragsearch|rag.*search ]]; then
            lambda_functions["rag_search"]="$physical_id"
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] マッチ: rag_search -> $physical_id" >&2
            fi
        elif [[ "$logical_id_lower" =~ resultchecker|result.*checker ]]; then
            lambda_functions["result_checker"]="$physical_id"
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] マッチ: result_checker -> $physical_id" >&2
            fi
        elif [[ "$logical_id_lower" =~ reviewrequest|review.*request ]]; then
            lambda_functions["review_request"]="$physical_id"
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] マッチ: review_request -> $physical_id" >&2
            fi
        elif [[ "$logical_id_lower" =~ revisionchecker|revision.*checker ]]; then
            lambda_functions["revision_checker"]="$physical_id"
            if [ "$DEBUG_MODE" = true ]; then
                echo "[DEBUG] マッチ: revision_checker -> $physical_id" >&2
            fi
        fi
    done < "$temp_file"
    
    # 一時ファイルをクリーンアップ
    rm -f "$temp_file"
    
    # 結果を標準出力に出力（戻り値として使用）
    for key in config_manager file_storage rag_search result_checker review_request revision_checker; do
        if [ -n "${lambda_functions[$key]}" ]; then
            echo "$key:${lambda_functions[$key]}"
        fi
    done
}

# === フロントエンドデプロイ ===
deploy_frontend() {
    echo "============================================================"
    echo " Phase 3-1: フロントエンドデプロイ"
    echo "============================================================"
    echo ""
    
    # フロントエンド資材の存在確認
    if ! aws s3 ls "$S3_BASE_PATH/dist/" &> /dev/null; then
        log_warning "フロントエンド資材が見つかりません: $S3_BASE_PATH/dist/"
        log_warning "フロントエンドデプロイをスキップします"
        return 0
    fi
    
    # フロントエンドS3バケット名取得
    log_info "フロントエンドS3バケット名を取得中..."
    local frontend_bucket=$(get_frontend_bucket)
    if [ $? -ne 0 ] || [ -z "$frontend_bucket" ]; then
        log_error "フロントエンドS3バケット名の取得に失敗しました"
        log_error "CloudFormationの出力でFrontendBucketNameが定義されているか確認してください"
        return 1
    fi
    
    log_success "フロントエンドS3バケット名取得完了: $frontend_bucket"
    
    # フロントエンド資材をS3にsync（古いファイルは削除）
    log_info "フロントエンド資材をS3バケットにデプロイ中..."
    aws s3 sync "$S3_BASE_PATH/dist/" "s3://$frontend_bucket/" \
        --region "$REGION" \
        --delete \
        --exact-timestamps
    
    if [ $? -eq 0 ]; then
        log_success "フロントエンドデプロイ完了"
        
        # CloudFrontキャッシュクリア（オプション）
        log_info "CloudFrontキャッシュをクリア中..."
        local cloudfront_id=$(get_cloudfront_distribution_id)
        
        if [ $? -eq 0 ] && [ -n "$cloudfront_id" ]; then
            log_info "CloudFront Distribution ID: $cloudfront_id"
            local invalidation_id=$(aws cloudfront create-invalidation \
                --distribution-id "$cloudfront_id" \
                --paths "/*" \
                --query 'Invalidation.Id' \
                --output text 2>/dev/null)
            
            if [ -n "$invalidation_id" ]; then
                log_success "CloudFrontキャッシュクリア開始: $invalidation_id"
            else
                log_warning "CloudFrontキャッシュクリアに失敗しました"
            fi
        else
            log_warning "CloudFront Distribution IDが取得できませんでした"
        fi
    else
        log_error "フロントエンドデプロイに失敗しました"
        return 1
    fi
}

# === バックエンドデプロイ ===
deploy_backend() {
    echo ""
    echo "============================================================"
    echo " Phase 3-2: バックエンドデプロイ"
    echo "============================================================"
    echo ""
    
    # Lambda関数名取得
    log_info "CloudFormationスタック内のLambda関数を検索中..."
    local lambda_mappings=($(get_lambda_function_names))
    
    if [ $? -ne 0 ] || [ ${#lambda_mappings[@]} -eq 0 ]; then
        log_error "CloudFormationスタック内からLambda関数名の取得に失敗しました"
        log_error "ネストされたスタックにLambda関数が定義されているか確認してください"
        return 1
    fi
    
    log_success "Lambda関数名取得完了: ${#lambda_mappings[@]}個の関数を検出"
    
    # 検出された関数の一覧を表示
    log_info "検出されたLambda関数 (CloudFormationスタック内):"
    for mapping in "${lambda_mappings[@]}"; do
        local zip_name="${mapping%%:*}"
        local function_name="${mapping##*:}"
        log_info "  - $zip_name → $function_name"
    done
    
    # 各Lambda関数にzipファイルをデプロイ
    local deployed_count=0
    local total_count=0
    
    for mapping in "${lambda_mappings[@]}"; do
        # key:valueの形式を分割
        local zip_name="${mapping%%:*}"
        local function_name="${mapping##*:}"
        
        total_count=$((total_count + 1))
        
        # 空の関数名をスキップ
        if [ -z "$function_name" ] || [ "$function_name" = "None" ]; then
            log_warning "Lambda関数名が取得できませんでした: $zip_name"
            continue
        fi
        
        # zipファイルの存在確認
        if ! aws s3 ls "$S3_BASE_PATH/lambda/${zip_name}.zip" &> /dev/null; then
            log_warning "Lambda資材が見つかりません: $S3_BASE_PATH/lambda/${zip_name}.zip"
            log_warning "${function_name}のデプロイをスキップします"
            continue
        fi
        
        log_info "Lambda関数を更新中: $function_name ($zip_name.zip)"
        
        # Lambda関数のコードを更新
        local s3_path_without_protocol="${S3_BASE_PATH#s3://}"
        local s3_bucket="${s3_path_without_protocol%%/*}"
        local s3_prefix="${s3_path_without_protocol#*/}"
        local s3_key="${s3_prefix}/lambda/${zip_name}.zip"
        
        log_debug "S3 Bucket: $s3_bucket"
        log_debug "S3 Key: $s3_key"
        
        aws lambda update-function-code \
            --function-name "$function_name" \
            --s3-bucket "$s3_bucket" \
            --s3-key "$s3_key" \
            --region "$REGION" > /dev/null
        
        if [ $? -eq 0 ]; then
            log_success "Lambda関数更新完了: $function_name"
            deployed_count=$((deployed_count + 1))
        else
            log_error "Lambda関数更新に失敗しました: $function_name"
        fi
    done
    
    log_info "バックエンドデプロイ結果: $deployed_count/$total_count 個のLambda関数が更新されました"
    
    if [ $deployed_count -gt 0 ]; then
        log_success "バックエンドデプロイ完了"
    else
        log_warning "バックエンドデプロイで更新されたLambda関数がありません"
    fi
}

# === デプロイ後の情報表示 ===
show_deployment_info() {
    
    log_info "デプロイ結果を取得中..."
    
    # スタック出力取得
    local outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs' \
        --output table 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$outputs" ]; then
        echo ""
        echo "============================================================"
        echo " デプロイ完了サマリ"
        echo "============================================================"
        echo ""
        echo "$outputs"
        echo ""
        
        # 主要なURLを取得して表示
        local cloudfront_url=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionUrl`].OutputValue' \
            --output text 2>/dev/null)
        
        local api_url=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayUrl`].OutputValue' \
            --output text 2>/dev/null)
        
        if [ -n "$cloudfront_url" ] && [ "$cloudfront_url" != "None" ]; then
            echo "フロントエンドURL: $cloudfront_url"
        fi
        
        if [ -n "$api_url" ] && [ "$api_url" != "None" ]; then
            echo "API URL: $api_url"
        fi
        
        echo ""
        echo "スタック名: $STACK_NAME"
        echo "リージョン: $REGION"
        echo "デプロイ方式: ネストテンプレート (CloudShell)"
        echo "S3ベースパス: $S3_BASE_PATH"
        echo "総スタック数: 22 (1 Main + 7 Core + 15 API Resources)"
        echo ""
        echo "ネストテンプレートデプロイが正常に完了しました！"
        echo ""
    else
        log_warning "スタック出力の取得に失敗しました"
    fi
}

# === 一時ファイルクリーンアップ ===
cleanup_temp_files() {
    if [ -n "$DOWNLOADED_PARAMETERS_FILE" ] && [ -f "$DOWNLOADED_PARAMETERS_FILE" ]; then
        rm -f "$DOWNLOADED_PARAMETERS_FILE"
        log_info "一時ファイルを削除しました: $DOWNLOADED_PARAMETERS_FILE"
    fi
}

# === メイン実行 ===
main() {
    echo ""
    echo "============================================================"
    echo " ReviewMaster CloudFormation ネストテンプレート デプロイ"
    echo " (CloudShell専用)"
    echo "============================================================"
    echo ""
    
    if [ "$DEBUG_MODE" = true ]; then
        log_info "デバッグモードが有効です"
        log_debug "S3_BASE_PATH: $S3_BASE_PATH"
        log_debug "STACK_NAME: $STACK_NAME"
        log_debug "REGION: $REGION"
    fi
    
    # 前提条件チェック
    check_prerequisites
    
    # S3資材存在確認
    check_s3_resources
    
    # パラメータファイルダウンロード
    download_parameters
    
    # テンプレート構文チェック
    validate_template
    
    # パラメータ読み込み
    log_info "パラメータを読み込み中..."
    local parameters=$(load_parameters)
    
    if [ $? -ne 0 ] || [ -z "$parameters" ]; then
        log_error "有効なパラメータが見つかりません"
        cleanup_temp_files
        exit 1
    fi
    
    log_info "デプロイパラメータ:"
    echo "$parameters" | tr ' ' '\n' | sed 's/^/  /'
    
    # 実行確認
    confirm_execution
    
    # 二段階デプロイ実行
    deploy_two_stage "$parameters"
    
    # フロントエンド・バックエンドデプロイ実行
    echo ""
    echo "============================================================"
    echo " Phase 3: フロントエンド・バックエンドデプロイ"
    echo "============================================================"
    echo ""
    
    deploy_frontend
    deploy_backend
    
    # 結果表示
    show_deployment_info
    
    # 一時ファイルクリーンアップ
    cleanup_temp_files
}

# エラー時のクリーンアップ
trap cleanup_temp_files EXIT

# スクリプト実行
main